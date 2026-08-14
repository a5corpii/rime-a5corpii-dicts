#!/bin/bash

# -------------------------- 文件变量命名区 --------------------------

# Rime 配置文件，读取installation_id
RIME_Instl="$HOME/.local/share/fcitx5/rime/installation.yaml"

# 输出词库 essay‑*.txt 格式：字词\t权重 两列tab分隔
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
ONE_MONTH_SEC=$((30 * 24 * 86400))

# 分数阈值
MAX_SCORE=3890
MIN_BASE_SCORE=43
# 筛选门槛：单字 c>1；多字 c>0
SINGLE_C_THRESHOLD=1
MULTI_C_THRESHOLD=0

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

# 提取Rime合规词条
# 规则：单字c>1；多字c>0；7天阻尼防短时爆炸；30d平滑衰减
extract_valid_rime_words() {
    local db_path="$1"
    local now_ts=$(date +%s)
    awk -F'\t' -v now="${now_ts}" -v month_sec="${ONE_MONTH_SEC}" \
        -v s_c_thr="${SINGLE_C_THRESHOLD}" -v m_c_thr="${MULTI_C_THRESHOLD}" '
BEGIN {
    MIN_BASE_SCORE = '"${MIN_BASE_SCORE}"'
}
/^#/ { next }
NF < 3 { next }
{
    word = $2
    word_len = length(word)
    split($3, field_arr, " ")

    c_val = substr(field_arr[1], 3) + 0
    d_val = substr(field_arr[2], 3) + 0
    t_val = 0
    # 解析t=时间戳
    for(f in field_arr){
        if(field_arr[f] ~ /^t=/){
            t_val = substr(field_arr[f],3) + 0
        }
    }

    # 必须全汉字
    if (word !~ /^[\u4E00-\u2A6DF]+$/ ) {
        next
    }

    # 分支判断：单字 / 多字门槛不同
    keep = 0
    if(word_len == 1){
        if(c_val > s_c_thr){
            keep = 1
        }
    }else{
        if(c_val > m_c_thr){
            keep = 1
        }
    }
    if(keep == 0){
        next
    }

    # 时间差计算
    delta_t = (now - t_val)
    if(delta_t < 0) delta_t = 0

    # 短时爆发抑制：7天内高频使用做阻尼，防止短时间刷爆权重
    local_damp = 1.0
    if(delta_t < 7*24*86400){
        local_damp = 0.25 + 0.75 * (delta_t/(7*24*86400))
    }

    # 按月平滑衰减系数：满一个月开始缓慢衰减，最小衰减系数0.4
    decay_factor = 1.0
    if(delta_t > month_sec){
        decay_factor = 1.0 - 0.35 * ((delta_t - month_sec) / (3.0 * month_sec))
        if(decay_factor < 0.4) decay_factor = 0.4
    }

    c_compress = log(c_val + 1)
    len_bonus = 1 + (word_len - 2) * 0.12

    raw_final = c_compress * d_val * len_bonus * local_damp * decay_factor
    score = int(log(raw_final + 1) * 120)

    print word "\t" score
}' "$db_path"
}

# 分数修剪：处理最终essay txt两列格式
# 规则：
#  1.无权重、权重非数字、权重<43 → 强制43
#  2.权重>3890 → 强制3890
#  3.43~3890原值保留
clip_max_score() {
    local limit="$1"
    local min="$2"
    awk -F'\t' -v max="$limit" -v min="$min" '
    {
        word=$1
        val=$2
        # 条件：字段不足2列 / 第二列不是数字 / 数值小于min
        if(NF<2 || val !~ /^[0-9]+$/ || val < min){
            printf("%s\t%d\n", word, min)
        }else if(val > max){
            printf("%s\t%d\n", word, max)
        }else{
            print $1"\t"$2
        }
    }
    '
}

# merge_stream_dedup
# $1子模块基底 $2原有词库 $3Rime新词流 $4黑名单文件 $5输出临时文件
# 逻辑：合并子模块 + 旧词库 + rime新词；同词条**保留权重最大值**；黑名单过滤；子模块删除词条会同步消失
merge_stream_dedup() {
    local submod_file="$1"
    local user_file="$2"
    local rime_stream="$3"
    local bl_file="$4"
    local tmp_out="$5"
    local bl_cnt=$(count_lines "$bl_file")

    # 全部数据源合并到临时流
    {
        cat "$submod_file" "$user_file"
        echo "$rime_stream"
    } > .merge_all.tmp

    # awk：同词条取最大权重
    awk -F'\t' '
    NF>=2 && $2~/^[0-9]+$/ {
        if( (!max_score[$1]) || ($2 > max_score[$1]) ){
            max_score[$1] = $2
        }
    }
    END{
        for(k in max_score){
            print k "\t" max_score[k]
        }
    }' .merge_all.tmp > .merge_max.tmp

    if [ "$bl_cnt" -gt 0 ]; then
        grep -v -f "$bl_file" .merge_max.tmp | clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" | sort -k1,1 > "$tmp_out"
    else
        clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" < .merge_max.tmp | sort -k1,1 > "$tmp_out"
    fi

    rm -f .merge_all.tmp .merge_max.tmp
    mv -f "$tmp_out" "$user_file"
}

# -------------------------- 前置流程 --------------------------

update_all_submodules

# 读取Rime同步配置，使用 terra_pinyin.userdb.txt
INSTALL_ID=$(grep 'installation_id:' "$RIME_Instl" | sed 's/.*installation_id:\s*//')
RIME_DB="$HOME/.local/share/fcitx5/rime/sync/${INSTALL_ID}/terra_pinyin.userdb.txt"

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
echo "✅ 繁体库完成：$T_OLD 行 → $T_NEW 行，黑名单过滤+分数修剪+按词条取最大权重共剔除 $T_DEL 条"

# -------------------------- 处理简体词库 --------------------------
echo -e "\n===== 处理简体词库 ====="
S_OLD=$(count_lines "$EssayHanS")
merge_stream_dedup "$SUBMOD_S_BASE" "$EssayHanS" "$NEW_SIMP_RIME" "$BLACKLIST_TMP_S" "$EssayHanS.tmp"
S_NEW=$(count_lines "$EssayHanS")
S_SUB_LINES=$(count_lines "$SUBMOD_S_BASE")
S_DEL=$(( S_SUB_LINES + S_OLD + NEW_RIME_COUNT - S_NEW ))
echo "✅ 简体库完成：$S_OLD 行 → $S_NEW 行，黑名单过滤+分数修剪+按词条取最大权重共剔除 $S_DEL 条"

# 清理临时黑名单
rm -f "$BLACKLIST_TMP_T" "$BLACKLIST_TMP_S"

# -------------------------- 统计与样例输出 --------------------------
echo -e "\n📊 整体统计信息"
echo "Rime词库提取有效词条：$NEW_RIME_COUNT 条"
echo "识别负c待删除词条总数：$BLACK_T_COUNT 条"
echo "繁体子模块基底总行数：$T_SUB_LINES 条"
echo "简体子模块基底总行数：$S_SUB_LINES 条"
echo "词条筛选门槛：单字 c>1(c≥2)；多字 c>0(c≥1)"
echo "子模块更新策略：30天内仅拉取一次，标记文件 .submodule_last_update.stamp"
echo "分数分层规则："
echo "  1. 引入时间阻尼：7天内高频输入抑制权重爆炸；超过30天平滑衰减；衰减后输出保底43，上限3890"
echo "  2. 最终txt输出：无权重/权重非数字/权重＜43 →强制43；权重＞3890→强制3890；中间原值保留"
echo "  3. 存量词库与新词条同key保留权重较大值；子模块增删改同步到最终输出词库；"
echo "黑名单策略：空黑名单直接跳过过滤，彻底杜绝词库清空"
echo "词条样例展示规则：均匀采样，固定输出最多15条"

echo -e "\n🔍 Rime新增词条均匀采样样例（最多15条）"
echo -e "\n===== 写入繁体库原文 ====="
sample_entries "$NEW_RAW_RIME" 15
echo -e "\n===== 转换后写入简体库 ====="
sample_entries "$NEW_SIMP_RIME" 15

echo -e "\n🎉 全部处理流程结束"
