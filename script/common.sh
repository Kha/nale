set -e
echo > times.csv

root=$PWD
bench() {
  bytes=$(ifconfig | sed -En 's/RX.*bytes ([0-9]+).*/\1/p' | sort -rn | head -n1)
  \time -f "$1,%e,%M" -ao $root/times.csv "${@:2}"
  bytes2=$(ifconfig | sed -En 's/RX.*bytes ([0-9]+).*/\1/p' | sort -rn | head -n1)
  mb=$(( (bytes2-bytes) / 1000000 ))
  sed -i "\$s/\$/,$mb/" $root/times.csv
}
toJson() {
  jq -Rsn '[inputs | . / "\n" | (.[] | select(length > 0) | . / ",") as $input |
    [{"name": $input[0], "unit": "s", "value": $input[1] },
    {"name": "\($input[0]) [RX]", "unit": "MB", "value": $input[3] }]] |
    flatten' < $root/times.csv > $root/times.json
}

commit=5c8ff9a
git clone https://github.com/leanprover/std4 || git -C std4 fetch
cd std4
git checkout $commit
