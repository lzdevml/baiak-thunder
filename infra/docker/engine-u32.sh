#!/bin/sh
# =============================================================
# Baiak Forge: patch u32 na engine nekiro (protocolgame.cpp).
# Manda level / vida / mana em 4 bytes (u32) em vez de u16 (max 65535),
# casando com o client mehah patchado (parsePlayerStats getU32).
# Roda no estagio builder, DEPOIS do git clone, ANTES do cmake.
# Usa '|' como delimitador do sed (evita escapar as barras).
# =============================================================
set -e
F="src/protocolgame.cpp"
[ -f "$F" ] || { echo "engine-u32: $F nao encontrado"; exit 1; }

sed -i 's|msg.add<uint16_t>(std::min<int32_t>(player->getHealth(), std::numeric_limits<uint16_t>::max()));|msg.add<uint32_t>(player->getHealth());|' "$F"
sed -i 's|msg.add<uint16_t>(std::min<int32_t>(player->getMaxHealth(), std::numeric_limits<uint16_t>::max()));|msg.add<uint32_t>(player->getMaxHealth());|' "$F"
sed -i 's|msg.add<uint16_t>(player->getLevel());|msg.add<uint32_t>(player->getLevel());|' "$F"
sed -i 's|msg.add<uint16_t>(std::min<int32_t>(player->getMana(), std::numeric_limits<uint16_t>::max()));|msg.add<uint32_t>(player->getMana());|' "$F"
sed -i 's|msg.add<uint16_t>(std::min<int32_t>(player->getMaxMana(), std::numeric_limits<uint16_t>::max()));|msg.add<uint32_t>(player->getMaxMana());|' "$F"

# valida que TODOS os 5 campos viraram u32 (senao aborta o build — evita desync silencioso)
for pat in 'add<uint32_t>(player->getHealth())' 'add<uint32_t>(player->getMaxHealth())' \
           'add<uint32_t>(player->getLevel())' 'add<uint32_t>(player->getMana())' \
           'add<uint32_t>(player->getMaxMana())'; do
    grep -qF "$pat" "$F" || { echo "engine-u32: FALHOU patch de [$pat]"; exit 1; }
done
echo "engine-u32: patch OK (level/hp/maxhp/mana/maxmana -> u32)"
