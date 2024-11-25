#!/bin/bash

cd $(dirname $0)

convert $1 ./images/wallpaper.png
convert $1 ./images/wallpaper.jpg
