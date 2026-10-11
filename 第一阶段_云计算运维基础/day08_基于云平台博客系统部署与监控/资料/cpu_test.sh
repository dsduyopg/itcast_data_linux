#!/bin/bash

# 启动 2 个 `yes` 进程，使 CPU 100% 占用
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &

# 让脚本保持运行
wait
