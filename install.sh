#!/bin/bash

# Interromopi lo script al primo errore
set -e

# --- Configurazione ---
CONFIG_FILES="etc"
SERVICE_FILES="etc/systemd/system"
BIN_FILES="usr/local/bin"

SOURCE_DIRS=("$CONFIG_FILES" "$SERVICE_FILES" "$BIN_FILES")

# Funzione di rollback
cleanup() {
  local exit_code=$?

  # Se non ci sono errori non fare nulla
  if [ $exit_code -eq 0 ]; then
    return
  fi
  echo ""
  echo "!!! ERRORE RILEVATO, ESECUZIONE ROLLBACK"

  # Eseguii rollback su errore
  for dir in "${SOURCE_DIRS[@]}/*"; do
    for file in $dir; do
      local dest_file="/$dir/$file"
      if [ -f "$dest_file" ]; then
        rm -f "$dest_file"
        echo "Rimosso file $dest_file"
      fi
    done
  done

  # Nota: systemctl daemon-reload non è reversibile, ma lo script si blocca prima se cp fallisce.

  echo "Rollback completato. Installazione annullata"
}

# Registra la funzione cleanup all'uscita
trap cleanup EXIT

# Verifica privilegio di root
if [ "$EUIID" -ne 0 ]; then
  echo "Errore: Eseguire con i privilegi di root"
  exit 1
fi

echo "Avvio installazione..."

# 1. Copia dei files
