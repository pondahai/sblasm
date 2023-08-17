#!/bin/bash

while read -r line; do
    IFS=' ' read -ra numbers <<< "$line"
    for num in "${numbers[@]}"; do
        hex=$(printf "%04X" "$num")
        hex="${hex: -4}"
        echo -n "$hex "
    done
    echo
done
