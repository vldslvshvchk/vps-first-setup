#!/bin/bash

# check root
if [[ $EUID -ne 0 ]]; then
   echo "Пожалуйста, запустите этот скрипт с правами root"
   echo "Используй sudo -i"
   echo "Затем запусти скрипт повторно"
   exit 1
fi
