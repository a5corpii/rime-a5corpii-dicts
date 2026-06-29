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
# 临时黑名单文件
BLACKLIST_TMP_T="./.blacklist_t.tmp"
BLACKLIST_TMP_S="./.blacklist_s.tmp"
# 子模块更新时间戳标记文件
SUBMODULE_STAMP="./.submodule_last_update.stamp"
# 30天秒数阈值
THIRTY_DAY_SEC=$((30 * 24 * 86400))

# -------------------------- 通用工具函数 --------------------------
# 统计文件行数
count_lines() {
    [ -f "$1" ] && wc -l < "$1" || echo 0
}

# 全局一次性更新所有子模块至远程最新，带30天冷却判断
update_all_submodules() {
    local now=$(date +%s)
    if [ -f "$SUBMODULE_STAMP" ]; then
        local last_update=$(cat "$SUBMODULE_STAMP")
        local diff_sec=$(( now - last_update ))
        if [ "$diff_sec" -lt "$THIRTY_DAY_SEC" ]; then
            echo -e "\nℹ️  30天内已执行过子模块更新，本次跳过 git submodule update --remote"
            return 0
        fi
    fi
    echo -e "\n🔄 全局一次性更新全部子模块至远程最新..."
    git submodule update --remote > /dev/null 2>&1
    echo "$now" > "$SUBMODULE_STAMP"
    echo "✅ 子模块更新完成，已记录本次更新时间戳"
}

# 均匀采样稳定输出指定条数，不足则全输出
sample_entries() {
    local stream="$1"
    local target="$2"
    echo "$stream" | awk -v N="$target" '
    {
        lines[NR] = $0;
        total = NR
    }
    END {
        if (total == 0) exit;
        take = (total < N) ? total : N;
        for (i = 0; i < take; i++) {
            pos = int(total * i / take) + 1;
            print lines[pos];
        }
    }'
}

# 提取负c黑名单词条（仅输出词条文本）
extract_negative_c_blacklist() {
    local db_path="$1"
    awk -F'\t' '
    /^#/ { next }
    NF < 3 { next }
    {
        split($3, field_arr, " ")
        c_val = substr(field_arr[1], 3) + 0
        if (c_val < 0) print $2
    }' "$db_path"
}

# 提取Rime合规繁体词条
extract_valid_rime_words() {
    local db_path="$1"
    awk -F'\t' '
BEGIN {
    now = systime()
    SINGLE_WORD_C_THRESHOLD = 20
}
/^#/ { next }
NF < 3 { next }
{
    word = $2
    word_len = length(word)
    split($3, field_arr, " ")
    c_val = substr(field_arr[1], 3) + 0
    d_val = substr(field_arr[2], 3) + 0
    t_val = substr(field_arr[3], 3) + 0

    if (word !~ /^[\u4E00-\u2A6DF]+$/ || c_val <= 0) next
    if (word_len == 1 && c_val < SINGLE_WORD_C_THRESHOLD) next

    day_diff = (now - t_val) / 86400
    decay = 1
    if (day_diff > 30) {
        decay = exp(-(day_diff - 30) / 180)
        if (decay < 0.3) decay = 0.3
    }

    c_compress = log(c_val + 1)
    len_bonus = 1 + (word_len - 2) * 0.12
    raw = c_compress * d_val * decay * len_bonus
    score = int(log(raw + 1) * 120)
    if (score < 43) score = 43
    print word "\t" score
}' "$db_path"
}

# 合并数据源、剔除黑名单、排序去重
# $1子模块基底 $2原有词库 $3Rime新词流 $4黑名单文件 $5输出临时文件
merge_stream_dedup() {
    local submod_file="$1"
    local user_file="$2"
    local rime_stream="$3"
    local bl_file="$4"
    local tmp_out="$5"
    local bl_cnt=$(count_lines "$bl_file")

    # 合并全部原始数据源
    cat "$submod_file" "$user_file" > .merge_all.tmp
    echo "$rime_stream" >> .merge_all.tmp

    if [ "$bl_cnt" -gt 0 ]; then
        # 存在黑名单，反向匹配删除词条
        grep -v -f "$bl_file" .merge_all.tmp | sort -k1,1 -k2,2nr | awk '!seen[$1]++' > "$tmp_out"
    else
        # 无黑名单，直接排序去重，不会清空
        sort -k1,1 -k2,2nr .merge_all.tmp | awk '!seen[$1]++' > "$tmp_out"
    fi

    rm -f .merge_all.tmp
    mv -f "$tmp_out" "$user_file"
}

# -------------------------- 前置流程 --------------------------
update_all_submodules

# 读取Rime同步配置
INSTALL_ID=$(grep 'installation_id:' "$RIME_Instl" | sed 's/.*installation_id:\s*//')
RIME_DB="$HOME/.local/share/fcitx5/rime/sync/${INSTALL_ID}/luna_pinyin.userdb.txt"
echo -e "\n📌 Rime环境信息"
echo "installation_id：$INSTALL_ID"
echo "用户词库路径：$RIME_DB"

# 生成负c黑名单
echo -e "\n🔍 提取c为负值的待删除词条黑名单"
extract_negative_c_blacklist "$RIME_DB" > "$BLACKLIST_TMP_T"
cat "$BLACKLIST_TMP_T" | opencc -c t2s.json > "$BLACKLIST_TMP_S"
BLACK_T_COUNT=$(count_lines "$BLACKLIST_TMP_T")
echo "共识别需清除负c词条：${BLACK_T_COUNT} 条"

# 提取合法Rime词条并转简体
NEW_RAW_RIME=$(extract_valid_rime_words "$RIME_DB")
NEW_RIME_COUNT=$(echo "$NEW_RAW_RIME" | wc -l)
NEW_SIMP_RIME=$(echo "$NEW_RAW_RIME" | opencc -c t2s.json)

# -------------------------- 处理繁体词库 --------------------------
echo -e "\n===== 处理繁体词库 ====="
T_OLD=$(count_lines "$EssayHanT")
merge_stream_dedup "$SUBMOD_T_BASE" "$EssayHanT" "$NEW_RAW_RIME" "$BLACKLIST_TMP_T" "$EssayHanT.tmp"
T_NEW=$(count_lines "$EssayHanT")
T_SUB_LINES=$(count_lines "$SUBMOD_T_BASE")
T_DEL=$(( T_SUB_LINES + T_OLD + NEW_RIME_COUNT - T_NEW ))
echo "✅ 繁体库完成：$T_OLD 行 → $T_NEW 行，合并去重+黑名单拦截共剔除 $T_DEL 条"

# -------------------------- 处理简体词库 --------------------------
echo -e "\n===== 处理简体词库 ====="
S_OLD=$(count_lines "$EssayHanS")
merge_stream_dedup "$SUBMOD_S_BASE" "$EssayHanS" "$NEW_SIMP_RIME" "$BLACKLIST_TMP_S" "$EssayHanS.tmp"
S_NEW=$(count_lines "$EssayHanS")
S_SUB_LINES=$(count_lines "$SUBMOD_S_BASE")
S_DEL=$(( S_SUB_LINES + S_OLD + NEW_RIME_COUNT - S_NEW ))
echo "✅ 简体库完成：$S_OLD 行 → $S_NEW 行，合并去重+黑名单拦截共剔除 $S_DEL 条"

# 清理临时黑名单
rm -f "$BLACKLIST_TMP_T" "$BLACKLIST_TMP_S"

# -------------------------- 统计与样例输出 --------------------------
echo -e "\n📊 整体统计信息"
echo "Rime词库提取有效词条：$NEW_RIME_COUNT 条"
echo "识别负c待删除词条总数：$BLACK_T_COUNT 条"
echo "繁体子模块基底总行数：$T_SUB_LINES 条"
echo "简体子模块基底总行数：$S_SUB_LINES 条"
echo "单字高频门槛：累计选用次数 ≥ 20"
echo "子模块更新策略：30天内仅拉取一次，标记文件 .submodule_last_update.stamp"
echo "分数规则：衰减最低0.3，线性平缓词长加成抑制高分爆炸，词条score保底43，无0分"
echo "黑名单策略：空黑名单直接跳过过滤，彻底杜绝词库清空"
echo "词条样例展示规则：均匀采样，固定输出最多15条"

echo -e "\n🔍 Rime新增词条均匀采样样例（最多15条）"
echo -e "\n===== 写入繁体库原文 ====="
sample_entries "$NEW_RAW_RIME" 15
echo -e "\n===== 转换后写入简体库 ====="
sample_entries "$NEW_SIMP_RIME" 15

echo -e "\n🎉 全部处理流程结束"
