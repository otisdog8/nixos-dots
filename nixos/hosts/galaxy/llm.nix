# Local LLM inference on galaxy (RTX 4090 24GB + RTX 5070 12GB).
#
# Stack: llama.cpp (CUDA) + llama-swap.
#   - llama.cpp is the only first-class stack for MISMATCHED consumer GPUs: it
#     splits by layer with an explicit per-GPU ratio (--tensor-split) and pins
#     KV/scratch to the big card (--main-gpu). vLLM/SGLang are ruled out:
#     their tensor parallel assumes homogeneous GPUs (usable VRAM capped at
#     2x the smallest card, mixed Ada+Blackwell unsupported). ollama would
#     work but its cross-GPU split is not tunable; skipped in favor of
#     hand-tuned llama-server flags.
#   - llama-swap (services.llama-swap) is an OpenAI-compatible proxy on one
#     port that starts/stops llama-server instances on demand per model, so
#     VRAM is only held while a model is in use (ttl unloads it after idle —
#     this is also a gaming box). Its built-in web UI doubles as the chat
#     frontend (no separate frontend service; Open WebUI was evaluated and
#     dropped — huge fragile Python closure).
#
# VRAM budget: the 4090 also drives the desktop — 10% (~2.4GiB) is reserved,
# so inference gets ~21.6GiB of it; the 5070 is headless, ~11.2GiB usable.
# That budget is encoded in --tensor-split 21,11 (weights and KV land in
# ~21.6:11.2 proportion), and each model's ctx is sized so its share stays
# inside both cards' budgets (see roster table).
#
# Multi-user + context — two regimes (researched against llama.cpp b9925):
#   - gemmas: --kv-unified (-kvu). Verified supported for SWA models (the
#     iSWA cache is built from unified caches, PR #14363). -c becomes ONE
#     SHARED pool: a single conversation can use the whole window, up to
#     --parallel N concurrent requests share it. (~37% batch-throughput cost
#     vs split slots in upstream benchmarks — irrelevant at 2-4 users.)
#   - qwens: static slots (--parallel N, each slot gets ctx/N — which is
#     also the single-conversation cap). Their hybrid-recurrent DeltaNet
#     state sits outside the attention KV cache and -kvu support for
#     hybrids is unconfirmed upstream — don't force it.
# KV cache type is per-model, driven by measured KL-divergence data: q8_0
# where it's safe (qwens < 0.04, gemma-31B 0.108), but f16 on gemma-26B-A4B
# (0.377 at q8_0 — its KV is unusually quantization-sensitive). Keep K and V
# types SYMMETRIC — mismatched pairs silently fall back to a 25-45x slower
# non-fused FA path. NEVER add --swa-full on the gemmas: all 60 layers grow
# with ctx and quantized-KV VRAM balloons mid-inference (issue #23978).
#
# Driver note: the RTX 5070 (Blackwell) is ONLY supported by the open kernel
# modules — our nvidia module already defaults openDrivers = true; don't turn
# that off on this host. Stable (>= 570) covers both cards.
#
# Endpoint:
#   http://127.0.0.1:8080      llama-swap UI + OpenAI-compatible API (/v1)
# Auth: llama-swap's built-in apiKeys guards all inference endpoints (accepts
# "Authorization: Bearer <key>" or "x-api-key: <key>"). The key comes from
# sops via an EnvironmentFile (never the store). NOTE: /health and the /ui/*
# web UI are EXEMPT from apiKeys by design — fine on loopback; if you later
# bind to the tailnet, the UI (model list, load/unload) is reachable without
# the key even though inference isn't. Front with nginx if that matters.
#
# ── One-time bootstrap ───────────────────────────────────────────────────────
# 1. Create the API key secret (dotenv-style, consumed as an EnvironmentFile;
#    mirrors the borg-repo-env pattern in ./backups.nix):
#      sops nixos/hosts/galaxy/secrets/galaxy.yaml
#        llama-swap-env: LLAMA_SWAP_API_KEY=sk-<openssl rand -base64 32>
#    llama-swap FAILS to start until this exists (config loading aborts on
#    unset ${env.*} references) — that's the desired fail-closed behavior.
# 2. The CUDA cache substituter below only takes effect AFTER an activation,
#    so pass it explicitly on the first rebuild or llama-cpp compiles from
#    source (verified: our exact llama-cpp store path is in the cache):
#      sudo nixos-rebuild switch --flake .#galaxy \
#        --option extra-substituters https://cache.nixos-cuda.org \
#        --option extra-trusted-public-keys cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=
# 3. Download the model files (as jrt; /large/models is never backed up —
#    blobs are re-downloadable):
#      hf download unsloth/gemma-4-26B-A4B-it-qat-GGUF gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf --local-dir /large/models
#      hf download unsloth/gemma-4-31B-it-qat-GGUF     gemma-4-31B-it-qat-UD-Q4_K_XL.gguf     --local-dir /large/models
#      hf download unsloth/Qwen3.6-27B-GGUF            Qwen3.6-27B-Q6_K.gguf                  --local-dir /large/models
#      hf download unsloth/Qwen3.6-35B-A3B-GGUF        Qwen3.6-35B-A3B-UD-Q4_K_M.gguf         --local-dir /large/models
#    No restart needed after downloads — llama-swap only opens a model file
#    when that model is first requested.
#
# ── Model roster & quant rationale ───────────────────────────────────────────
# Every model splits across BOTH cards: llama-swap runs one model at a time,
# so a "4090-only" model would leave the 5070's 11+GiB idle — splitting costs
# a little per-token PCIe overhead but buys that VRAM back as context. KV
# cost still varies wildly across these architectures (hybrid/SWA models only
# pay full KV on their global-attention layers), which drives the ctx picks
# (budget: ~21.6 GiB on the 4090 after the desktop reserve + ~11.2 GiB on
# the 5070, minus weights and ~1.5 GiB/GPU compute buffers):
#
#   model               quant        file    KV type  ctx pool      headroom
#   gemma-4-26B-A4B    QAT UD-Q4_K_XL 14.2GB  f16     256k shared/4  ~6GiB
#   qwen3.6-27B        Q6_K           22.5GB  q8_0    2x96k slots    ~2.5GiB
#   qwen3.6-35B-A3B    UD-Q4_K_M      22.1GB  q8_0    4x128k slots   ~4GiB
#   gemma-4-31B        QAT UD-Q4_K_XL 17.3GB  q8_0    128k shared/2  ~2GiB
#
#   - gemma QAT quants are ~bf16 quality at Q4 size — bigger quants of these
#     buy almost nothing, so both gemmas run QAT and spend the savings on KV.
#   - gemma-4-26B-A4B (MoE, 4B active) is the fast daily driver. Its pool is
#     the full 262144 NATIVE context (gemma 4 has no YaRN — 256k is the hard
#     ceiling per conversation, so a bigger pool would only help concurrency,
#     and f16 KV eats the rest of the headroom anyway).
#   - qwen3.6-27B is the quality flagship: Q6_K (near-lossless). Its KV is
#     mid-priced, so 2 slots x 96k is what fits next to the big weights.
#     (Qwen3.6 supports YaRN to 1M — irrelevant here, VRAM-bound.)
#   - qwen3.6-35B-A3B (MoE, 3B active) is speed + long context; hybrid
#     attention makes 4x128k cost only ~5.3GiB. Stays at UD-Q4_K_M to fit
#     the weight budget — the Q6 27B covers the max-quality slot.
#   - gemma-4-31B is the KV hog (~2.7GiB per 32k at q8_0 on 10 global
#     layers, plus ~0.4GiB/slot SWA cache) — a 128k shared pool is the
#     ceiling; its 13GiB KV budget supports ~150k tokens total.
#
# Multi-turn prompt caching on the qwens: historically broken for DeltaNet
# hybrids (issue #22384 — full-history reprocess every turn), FIXED for our
# build by PR #22673 (2026-05-16, per-token snapshots / partial seq_rm on
# hybrid memory; b9925 postdates it). --reasoning-preserve (suggested by the
# server itself at load, and Qwen's model card) keeps thinking blocks in the
# multi-turn context so the cached prefix actually matches — without it,
# stripped reasoning changes the prompt and cache hits degrade. Tradeoff:
# history (and context use) grows by the thinking tokens. If turn latency ever grows linearly
# with conversation length here, that regressed — check upstream. Still
# open upstream but irrelevant to us: checkpoints don't survive explicit
# /slots save/restore (#25913). Qwen3.6 also has MTP speculative decoding
# (--spec-type draft-mtp, ~1.7x decode) but it requires --parallel 1 —
# trade multi-user for speed if you ever want it.
#
# All four are vision models (GGUF repos ship mmproj-*.gguf) — vision is NOT
# wired up here; to enable, download the mmproj file and add "--mmproj
# <path>" to that model's cmd (costs ~1GB VRAM). Gemma 4 also ships MTP
# draft models for speculative decoding; llama.cpp support for those is not
# yet confirmed, so not wired either. Both qwens + gemmas think by default;
# --jinja is on for tool calling. To force a gemma into non-thinking mode,
# add: --chat-template-kwargs '{"enable_thinking":false}'
#
# ── Adding a model ───────────────────────────────────────────────────────────
# Add an entry under services.llama-swap.settings.models. Sizing rules for
# this box: weights + ~1.5GB/GPU compute buffers + KV <= 21.5GB (4090) /
# 11.5GB (5070). Use llama-bench (installed) to tune; watch real usage with
# nvtop. Big MoE models (gpt-oss-120b class) can push routed experts to
# system RAM with --n-cpu-moe N — needs ~64GB+ RAM.
#
# ── GPU research beyond llama.cpp ────────────────────────────────────────────
# Not-in-nixpkgs stacks (TabbyAPI/ExLlamaV3, ik_llama.cpp, ktransformers) are
# easiest via containers: enable virtualisation.podman +
# hardware.nvidia-container-toolkit (CDI: `--device nvidia.com/gpu=all`).
# For ad-hoc CUDA dev shells, cudaPackages.cudatoolkit in a nix shell works
# with the cache below.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  llamaCpp = pkgs.llama-cpp.override { cudaSupport = true; };
  llamaServer = lib.getExe' llamaCpp "llama-server";
  modelDir = "/large/models";

  # CUDA enumerates FASTEST_FIRST by default, so device 0 = 4090, 1 = 5070
  # (made explicit via CUDA_DEVICE_ORDER on the unit below). --tensor-split
  # is proportional — 21,11 encodes the usable-VRAM budget (4090 minus the
  # 10% desktop reserve : 5070), and --main-gpu 0 keeps scratch buffers on
  # the big card.
  baseFlags = "--n-gpu-layers 999 --flash-attn on --jinja";
  # Server-side sampler defaults straight from each HF model card ("thinking
  # mode, general tasks" profile for the qwens; gemma uses one standardized
  # config "across all use cases"). Clients that send their own sampling
  # params still override these — but clients that send nothing (or temp 0)
  # no longer trigger thinking-mode repetition loops. Per-card quirks: the
  # 35B card wants presence_penalty 1.5 in general thinking, the 27B card
  # 0.0 (its sanctioned anti-loop dial is presence_penalty 0-2 — raise it
  # first if loops recur); both qwen cards say temp 0.6 for precise coding,
  # worth sending from coding clients.
  qwenSamplers = "--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0";
  gemmaSamplers = "--temp 1.0 --top-p 0.95 --top-k 64";
  # Symmetric q8_0 KV — per-model, NOT in baseFlags: gemma-26B's KV degrades
  # measurably at q8_0 and runs f16 instead (see header).
  kvQ8 = "--cache-type-k q8_0 --cache-type-v q8_0";
  bothGpus = "--split-mode layer --tensor-split 21,11 --main-gpu 0";
  # llama-swap substitutes ''${PORT}; the literal must survive into the YAML.
  portFlag = "--port \${PORT}";
in
{
  # Community CUDA binary cache (CI-builds nixpkgs-unstable with cudaSupport).
  # Successor to cuda-maintainers.cachix.org. Without it, llama-cpp + friends
  # compile from source (nvcc, ~all sm archs — slow but harmless).
  nix.settings = {
    substituters = [ "https://cache.nixos-cuda.org" ];
    trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
  };

  # Keep the driver initialized between requests (llama-swap cold-starts
  # llama-server per model; without this each start pays device re-init).
  hardware.nvidia.nvidiaPersistenced = true;

  # CUDA normally loads nvidia_uvm on demand via modprobe — but the hardened
  # llama-swap unit has ProtectKernelModules=true, so the first CUDA init
  # inside the service would fail if the module isn't already loaded.
  boot.kernelModules = [ "nvidia_uvm" ];

  # Model blobs live on /large (never backed up, survives root wipe). Owned by
  # jrt for password-less downloads; world-readable so llama-swap's
  # DynamicUser can open them.
  systemd.tmpfiles.rules = [ "d ${modelDir} 0755 ${username} users -" ];

  # API key for llama-swap, resolved from ''${env.*} at config load. Dotenv
  # line: LLAMA_SWAP_API_KEY=sk-... (see bootstrap above).
  sops.secrets."llama-swap-env" = {
    restartUnits = [ "llama-swap.service" ]; # bounce on rotation
  };

  # ── llama-swap: one OpenAI-compatible endpoint, models loaded on demand ────
  services.llama-swap = {
    enable = true;
    # listenAddress default "localhost", port 8080.
    settings = {
      # Big models take a while to mmap+upload to VRAM on first request.
      healthCheckTimeout = 300;
      # Inference auth (UI and /health stay open — see header).
      apiKeys = [ "\${env.LLAMA_SWAP_API_KEY}" ];
      models = {
        # Fast daily driver: MoE (4B active), QAT quant, f16 KV (quant-
        # sensitive — see header). Unified pool = full native 256k for a
        # single conversation, shared by up to 4.
        "gemma-4-26b-a4b" = {
          cmd = "${llamaServer} ${portFlag} -m ${modelDir}/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf ${baseFlags} ${gemmaSamplers} ${bothGpus} --kv-unified --ctx-size 262144 --parallel 4";
          aliases = [ "gemma-fast" ];
          ttl = 1800; # free VRAM after 30min idle (gaming box)
        };
        # Quality flagship: dense 27B at near-lossless Q6_K. Hybrid
        # attention (16/64 global layers); 2x96k = ~6.4GiB KV is what fits
        # next to 21GiB of weights. Static slots (hybrid: no -kvu).
        "qwen3.6-27b" = {
          cmd = "${llamaServer} ${portFlag} -m ${modelDir}/Qwen3.6-27B-Q6_K.gguf ${baseFlags} ${qwenSamplers} ${kvQ8} ${bothGpus} --reasoning-preserve --ctx-size 196608 --parallel 2";
          aliases = [ "qwen-quality" ];
          ttl = 1800;
        };
        # Speed + long context: MoE (3B active), hybrid attention makes KV
        # nearly free (~5.3GiB for 4x128k). Static slots (hybrid: no -kvu).
        "qwen3.6-35b-a3b" = {
          cmd = "${llamaServer} ${portFlag} -m ${modelDir}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf ${baseFlags} ${qwenSamplers} --presence-penalty 1.5 ${kvQ8} ${bothGpus} --reasoning-preserve --ctx-size 524288 --parallel 4";
          aliases = [ "qwen-fast" ];
          ttl = 1800;
        };
        # Dense gemma at QAT quality; the KV hog of the roster. Unified
        # 128k pool (single conversation can use all of it; 2 concurrent
        # share) — ~10.9GiB KV + ~0.4GiB/slot SWA at q8_0.
        "gemma-4-31b" = {
          cmd = "${llamaServer} ${portFlag} -m ${modelDir}/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf ${baseFlags} ${gemmaSamplers} ${kvQ8} ${bothGpus} --kv-unified --ctx-size 131072 --parallel 2";
          aliases = [ "gemma-quality" ];
          ttl = 1800;
        };
      };
    };
  };
  systemd.services.llama-swap = {
    # CUDA device order for every llama-server llama-swap spawns (see
    # baseFlags comment). FASTEST_FIRST is the CUDA default; set explicitly
    # so configs that assume "0 = 4090" stay true even if a future driver
    # changes it.
    environment.CUDA_DEVICE_ORDER = "FASTEST_FIRST";
    # Injects LLAMA_SWAP_API_KEY; read by the systemd manager as root, so it
    # works despite DynamicUser.
    serviceConfig.EnvironmentFile = [ config.sops.secrets."llama-swap-env".path ];
  };

  # ── Tooling ────────────────────────────────────────────────────────────────
  environment.systemPackages = [
    llamaCpp # llama-cli / llama-bench / llama-quantize for research + tuning
    pkgs.nvtopPackages.nvidia # per-GPU utilization/VRAM monitor
    pkgs.python3Packages.huggingface-hub # `hf download ...` for fetching GGUFs
  ];

  # Optional: power-limit the 4090 for sustained inference (450W stock; 360W
  # loses only a few % throughput and a lot of heat/noise). Left OFF because
  # this is also the gaming GPU — uncomment to enable.
  # systemd.services.nvidia-power-limit = {
  #   description = "Cap RTX 4090 power for sustained inference";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [ "nvidia-persistenced.service" ];
  #   serviceConfig.Type = "oneshot";
  #   script = ''
  #     smi=${config.hardware.nvidia.package.bin}/bin/nvidia-smi
  #     uuid=$($smi --query-gpu=uuid,name --format=csv,noheader | ${pkgs.gawk}/bin/awk -F', ' '/4090/{print $1}')
  #     $smi -i "$uuid" -pl 360
  #   '';
  # };
}
