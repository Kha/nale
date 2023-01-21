set -e
echo > times.csv

root=$PWD
bench() {
  bytes=$(ifconfig | sed -En 's/RX.*bytes ([0-9]+).*/\1/p' | sort -rn | head -n1)
  fsmb=$(du -sm ~ | cut -f1)
  \time -f "$1,%e,%M" -ao $root/times.csv "${@:2}"
  bytes2=$(ifconfig | sed -En 's/RX.*bytes ([0-9]+).*/\1/p' | sort -rn | head -n1)
  fsmb2=$(du -sm ~ | cut -f1)
  mb=$(python3 -c "print(($bytes2-$bytes) / 1000000)")
  fsdelta=$((fsmb2-fsmb))
  sed -i "\$s/\$/,$mb,$fsdelta/" $root/times.csv
}
toJson() {
  jq -Rsn '[inputs | . / "\n" | (.[] | select(length > 0) | . / ",") as $input |
    [{"name": $input[0], "unit": "s", "value": $input[1] },
     {"name": "\($input[0]) [RX]", "unit": "MB", "value": $input[3] },
     {"name": "\($input[0]) [disk]", "unit": "MB", "value": $input[4] }]] |
    flatten' < $root/times.csv > $root/times.json
}

commit=5770b60
git clone https://github.com/leanprover/std4 || git -C std4 fetch
cd std4
git checkout $commit
