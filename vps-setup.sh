#!/bin/bash

# check root
[[ $EUID -ne 0 ]] && { echo "Этот скрипт должен быть запущен с правами root"; exit 1; }
