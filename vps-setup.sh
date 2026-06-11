#!/bin/bash

# check root
[[ $EUID -ne 0 ]] && { echo "Пожалуйста, запустите этот скрипт с правами root"; echo "Используй команду sudo -i чтоб попасть в сессию root"; exit 1; }
