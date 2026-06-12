#!/usr/bin/env bash
#
# Cut the bare round watch face out of a full-watch cfg render.
#
# The gallery shots (docs/cfg-*.png) are the simulator's full device skin (case,
# bezel, band) at 1:1 with the SDK device image, so the screen sits at a fixed
# rectangle = the device's `display.location` in its simulator.json. We crop that
# rectangle and apply a circular alpha mask (display.shape = round), leaving just
# the round face on transparent.
#
# Usage: cut-face.sh <in.png> <WxH+X+Y> <radius> <out.png>
#   e.g. cut-face.sh docs/cfg-default.png 390x390+149+234 195 bin/face-default.png
#
# Screen rects (from <device>/simulator.json display.location):
#   marq2aviator  390x390+149+234  r=195
#   fenix843mm    416x416+96+196   r=208
set -euo pipefail
in="$1"; geom="$2"; r="$3"; out="$4"
magick "$in" -crop "$geom" +repage \
  \( +clone -alpha extract -fill black -colorize 100 -fill white -draw "circle $r,$r $r,0" \) \
  -alpha off -compose CopyOpacity -composite "$out"
