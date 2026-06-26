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

# 提取Rime合规繁体词条
# 规则更新：
# 1. 两字及以上：纯汉字、c>0，无次数门槛
# 2. 单字：纯汉字、c>0、c≥20 高频门槛才保留
# 3. c使用对数压缩，超高次数不会让分数过度膨胀
# 4. 新增词长增益：字数越长附加权重越高，弥补长词使用频次低
# 5. score保底最低43，杜绝0分入库
# 计分逻辑统一，老词衰减最低0.3不归零
extract_valid_rime_words() {
    local db_path="$1"
    awk -F'\t' '
BEGIN {
    now = systime()
    # 单字词频门槛下调至20
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

    # 基础前置过滤：必须全汉字、c>0
    if (word !~ /^[\u4E00-\u2A6DF]+$/ || c_val <= 0) {
        next
    }

    # 分支规则：区分单字 / 多字词
    if (word_len == 1) {
        # 单字额外限制：累计选用次数≥20才保留
        if (c_val < SINGLE_WORD_C_THRESHOLD) {
            next
        }
    }
    # word_len ≥2 无额外限制，直接放行

    # 统一计分逻辑（单字/多字共用）
    day_diff = (now - t_val) / 86400
    decay = 1
    if (day_diff > 30) {
        decay = exp(-(day_diff - 30) / 180)
        if (decay < 0.3) decay = 0.3
    }
    # 对c取对数，压制超大c的权重膨胀
    c_compress = log(c_val + 1)
    # 词长增益：越长的词附加权重越高，平衡长词使用次数少的劣势
    len_bonus = 1 + log(word_len)
    raw = c_compress * d_val * decay * len_bonus
    score = int(log(raw + 1) * 120)
    # 保底最低43，杜绝低分/0分词条
    if (score < 43) score = 43
    print word "\t" score
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
echo "Rime词库提取有效词条：$NEW_RIME_COUNT 条"
echo "繁体子模块基底总行数：$T_SUB_LINES 条"
echo "简体子模块基底总行数：$S_SUB_LINES 条"
echo "单字高频门槛：累计选用次数 ≥ 20"
echo "分数规则：衰减最低0.3，词长越长附加权重越高，词条score保底43，无0分"
echo "词条样例展示规则：均匀采样，固定输出最多15条"

echo -e "\n🔍 Rime新增词条均匀采样样例（最多15条）"
echo -e "\n===== 写入繁体库原文 ====="
sample_entries "$NEW_RAW_RIME" 15
echo -e "\n===== 转换后写入简体库 ====="
sample_entries "$NEW_SIMP_RIME" 15

echo -e "\n🎉 全部处理流程结束"
