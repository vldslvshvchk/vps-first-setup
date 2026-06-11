#!/bin/bash

# check root
if [[ $EUID -ne 0 ]]; then
   echo "Пожалуйста, запустите этот скрипт с правами root"
   echo "Используйте sudo -i"
   echo "Затем запустите скрипт повторно"
   exit 1
fi
