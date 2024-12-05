#!/bin/bash
sudo apt install libsnappy-dev

git submodule update --recursive --init

mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release .. && cmake --build .

# For debug symbol.
# cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo .. && cmake --build .
