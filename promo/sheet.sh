#!/bin/sh
# sheet.sh dir: tiles every jpg in dir into 2x2 contact sheets (sheet-N.jpg)
D=$1; FF=$(dirname $0)/node_modules/ffmpeg-static/ffmpeg
ls $D/t*.jpg | sort > $D/list.txt
n=0; i=0; set --
while read f; do set -- "$@" -i "$f"; i=$((i+1)); if [ $i -eq 4 ]; then $FF -nostdin -loglevel error -y "$@" -filter_complex "[0]scale=960:540[a];[1]scale=960:540[b];[2]scale=960:540[c];[3]scale=960:540[d];[a][b][c][d]xstack=inputs=4:layout=0_0|960_0|0_540|960_540" $D/sheet-$n.jpg; n=$((n+1)); i=0; set --; fi; done < $D/list.txt
