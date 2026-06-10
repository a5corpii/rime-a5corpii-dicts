#!/bin/bash

# -------------------------- 文件变量命名区 --------------------------
# Rime 配置文件，读取installation_id
RIME_Instl="$HOME/.local/share/fcitx5/rime/installation.yaml"
# 输出词库
EssayHanT="./essay-a5corpii.txt"
EssayHanS="./essay-hans-a5corpii.txt"
# 繁体子模块
SUBMOD_T_DIR="./rime-essay"
SUBMOD_T_BASE="${SUBMOD_T_DIR}/essay.txt"
# 简体子模块
SUBMOD_S_DIR="./rime-essay-simp"
SUBMOD_S_BASE="${SUBMOD_S_DIR}/essay-zh-hans.txt"

# -------------------------- 通用工具函数 --------------------------
# 统计文件行数
count_lines() {
    [ -f "$1" ] && wc -l < "$1" || echo 0
}

# 全局一次性更新所有子模块至远程最新
update_all_submodules() {
    echo -e "\n🔄 全局一次性更新全部子模块至远程最新..."
    git submodule update --remote > /dev/null 2>&1
}

# 提取Rime合规繁体词条（汉字个数≥2、CJK ExtA/B、c>0、防score衰减归零）
extract_valid_rime_words() {
    local db_path="$1"
    awk -F'\t' '
BEGIN {
    now = systime()
}
/^#/ { next }
NF < 3 { next }
# 保留汉字个数≥2规则不变
length($2) < 2 { next }
# 覆盖基本汉字+ExtA+ExtB
$2 !~ /^[\u4E00-\u2A6DF]+$/ { next }
{
  split($3, field_arr, " ")
  c_val = substr(field_arr[1], 3) + 0
  d_val = substr(field_arr[2], 3) + 0
  t_val = substr(field_arr[3], 3) + 0

  # 仅保留人工选用过的词条
  if (c_val > 0) {
      day_diff = (now - t_val) / 86400
      decay = 1
      if (day_diff > 30) {
          decay = exp(-(day_diff - 30) / 180)
          # 衰减最低锁定0.2，永远不会衰减至0
          if (decay < 0.2) decay = 0.2
      }
      raw = c_val * d_val * decay
      score = int(log(raw + 1) * 120)
      print $2 "\t" score
  }
}' "$db_path"
}

# 合并数据流并去重：最新完整子模块基底 + 用户原有库 + Rime新词
# $1:子模块完整基底文件路径 $2:用户旧库文件 $3:rime新增词条流 $4:临时输出文件
merge_stream_dedup() {
    local submod_file="$1"
    local user_file="$2"
    local rime_new_stream="$3"
    local tmp_out="$4"

    {
        cat "$submod_file"
        cat "$user_file"
        echo "$rime_new_stream"
    } | sort -k1,1 -k2,2nr | awk '!record[$1]++' > "$tmp_out"
    mv -f "$tmp_out" "$user_file"
}

# -------------------------- 前置执行：全局更新子模块 + 读取Rime配置 --------------------------
# 1. 全局更新所有子模块，本地子模块文件为远程最新完整版本
update_all_submodules

# 2. 读取Rime安装ID，获取用户词库路径
INSTALL_ID=$(grep 'installation_id:' "$RIME_Instl" | sed 's/.*installation_id:\s*//')
RIME_DB="$HOME/.local/share/fcitx5/rime/sync/${INSTALL_ID}/luna_pinyin.userdb.txt"
echo -e "\n📌 Rime环境信息"
echo "installation_id：$INSTALL_ID"
echo "用户词库路径：$RIME_DB"

# 3. 预提取Rime繁体合规词条，一次性转换简体备用
NEW_RAW_RIME=$(extract_valid_rime_words "$RIME_DB")
NEW_RIME_COUNT=$(echo "$NEW_RAW_RIME" | wc -l)
NEW_SIMP_RIME=$(echo "$NEW_RAW_RIME" | opencc -c t2s.json)

# -------------------------- 分步处理繁体库 EssayHanT --------------------------
echo -e "\n===== 处理繁体词库 ====="
T_OLD=$(count_lines "$EssayHanT")
merge_stream_dedup "$SUBMOD_T_BASE" "$EssayHanT" "$NEW_RAW_RIME" "$EssayHanT.tmp"
T_NEW=$(count_lines "$EssayHanT")
T_SUB_LINES=$(count_lines "$SUBMOD_T_BASE")
T_DEL=$(( T_SUB_LINES + T_OLD + NEW_RIME_COUNT - T_NEW ))
echo "✅ 繁体库完成：$T_OLD 行 → $T_NEW 行，合并去重删除 $T_DEL 条重复"

# -------------------------- 分步处理简体库 EssayHanS --------------------------
echo -e "\n===== 处理简体词库 ====="
S_OLD=$(count_lines "$EssayHanS")
merge_stream_dedup "$SUBMOD_S_BASE" "$EssayHanS" "$NEW_SIMP_RIME" "$EssayHanS.tmp"
S_NEW=$(count_lines "$EssayHanS")
S_SUB_LINES=$(count_lines "$SUBMOD_S_BASE")
S_DEL=$(( S_SUB_LINES + S_OLD + NEW_RIME_COUNT - S_NEW ))
echo "✅ 简体库完成：$S_OLD 行 → $S_NEW 行，合并去重删除 $S_DEL 条重复"

# -------------------------- 终端统计与样例展示 --------------------------
echo -e "\n📊 整体统计信息"
echo "Rime词库提取有效新词：$NEW_RIME_COUNT 条"
echo "繁体子模块基底总行数：$T_SUB_LINES 条"
echo "简体子模块基底总行数：$S_SUB_LINES 条"

echo -e "\n🔍 Rime新增词条样例（前20条）"
echo -e "\n繁体原文词条："
echo "$NEW_RAW_RIME" | head -20
echo -e "\n转换后简体词条："
echo "$NEW_RAW_RIME" | opencc -c t2s.json | head -20

echo -e "\n🎉 全部处理流程结束"
