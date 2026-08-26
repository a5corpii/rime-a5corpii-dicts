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
# 分数阈值
MAX_SCORE=3890
MIN_BASE_SCORE=43
# 筛选门槛：单字 c>1；多字 c>0
SINGLE_C_THRESHOLD=1
MULTI_C_THRESHOLD=0

# -------------------------- 通用工具函数 --------------------------
count_lines() {
    [ -f "$1" ] && wc -l < "$1" || echo 0
}

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
# 规则：
# 1.是否纳入完全由c决定，t仅调整分数，不做删除
# 2.30天内新词：decay_factor=1.0，不做时间衰减；超过30天才衰减
# 3.时间因子影响被压缩，c频次为权重主导；保留7天短时阻尼抑制爆分
extract_valid_rime_words() {
    local db_path="$1"
    local now_ts=$(date +%s)
    awk -F'\t' -v now="${now_ts}" -v month_sec="${THIRTY_DAY_SEC}" \
        -v s_c_thr="${SINGLE_C_THRESHOLD}" -v m_c_thr="${MULTI_C_THRESHOLD}" '
{
    word = $2
    word_len = length(word)
    split($3, field_arr, " ")
    c_val = substr(field_arr[1], 3) + 0
    d_val = substr(field_arr[2], 3) + 0
    t_val = 0
    for(f in field_arr){
        if(field_arr[f] ~ /^t=/){
            t_val = substr(field_arr[f],3) + 0
        }
    }
    # 过滤：只看汉字校验 + c门槛；t不参与词条去留判断
    if (word !~ /^[\u4E00-\u2A6DF]+$/ ) {
        next
    }
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
    delta_t = (now - t_val)
    if(delta_t < 0) delta_t = 0
    # 7天短时阻尼：抑制短时间大量重复输入造成权重爆炸
    local_damp = 1.0
    if(delta_t < 7*24*86400){
        local_damp = 0.4 + 0.6 * (delta_t/(7*24*86400))
    }
    # --------时间衰减逻辑修改----------
    # 30天以内完全不衰减，decay_factor固定1.0；超过30天才启动衰减
    decay_factor = 1.0
    if(delta_t > month_sec){
        # 衰减幅度收窄，下限抬高至0.7，降低时间对权重的干预，c起主导
        decay_factor = 1.0 - 0.20 * ((delta_t - month_sec) / (3.0 * month_sec))
        if(decay_factor < 0.7) decay_factor = 0.7
    }
    c_compress = log(c_val + 1)
    len_bonus = 1 + (word_len - 2) * 0.12
    raw_final = c_compress * d_val * len_bonus * local_damp * decay_factor
    score = int(log(raw_final + 1) * 120)
    print word "\t" score
}' "$db_path"
}

# 权重钳位：强制 [MIN, MAX]
clip_max_score() {
    local limit="$1"
    local min="$2"
    awk -F'\t' -v max="$limit" -v min="$min" '
    {
        word=$1
        val=$2
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

merge_stream_dedup() {
    local submod_file="$1"
    local user_file="$2"
    local rime_stream="$3"
    local bl_file="$4"
    local tmp_out="$5"
    local bl_cnt=$(count_lines "$bl_file")

    # =========修复：全部来源先做权重钳位，再合并=========
    # 1.子模块原始库先clip
    clip_submod=$(mktemp .submod_clip.XXXXXX.tmp)
    clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" < "$submod_file" > "$clip_submod"

    # 2.旧user词库先clip
    clip_user=$(mktemp .user_clip.XXXXXX.tmp)
    if [ -f "$user_file" ]; then
        clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" < "$user_file" > "$clip_user"
    else
        touch "$clip_user"
    fi

    # 3.rime输出流源头clip
    clip_rime=$(mktemp .rime_clip.XXXXXX.tmp)
    echo "$rime_stream" | clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" > "$clip_rime"

    {
        cat "$clip_submod"
        cat "$clip_user"
        cat "$clip_rime"
    } > .merge_all.tmp

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
        grep -v -f "$bl_file" .merge_max.tmp | sort -k1,1 > "$tmp_out"
    else
        sort -k1,1 .merge_max.tmp > "$tmp_out"
    fi

    # 兜底二次clip，万无一失
    mv "$tmp_out" "${tmp_out}.preclip"
    clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" < "${tmp_out}.preclip" > "$tmp_out"
    rm -f "${tmp_out}.preclip"

    # 清理临时文件
    rm -f "$clip_submod" "$clip_user" "$clip_rime" .merge_all.tmp .merge_max.tmp
    mv -f "$tmp_out" "$user_file"
}

# -------------------------- 前置流程 --------------------------
update_all_submodules
INSTALL_ID=$(grep 'installation_id:' "$RIME_Instl" | sed 's/.*installation_id:\s*//')
# 已修改：terra_pinyin.userdb.txt
RIME_DB="$HOME/.local/share/fcitx5/rime/sync/${INSTALL_ID}/terra_pinyin.userdb.txt"

echo -e "\n📌 Rime环境信息"
echo "installation_id：$INSTALL_ID"
echo "用户词库路径：$RIME_DB"
echo -e "\n🔍 提取c为负值的待删除词条黑名单"
extract_negative_c_blacklist "$RIME_DB" > "$BLACKLIST_TMP_T"
cat "$BLACKLIST_TMP_T" | opencc -c t2s.json > "$BLACKLIST_TMP_S"
BLACK_T_COUNT=$(count_lines "$BLACKLIST_TMP_T")
echo "共识别需清除负c词条：${BLACK_T_COUNT} 条"

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

rm -f "$BLACKLIST_TMP_T" "$BLACKLIST_TMP_S"

# -------------------------- 统计与样例输出 --------------------------
echo -e "\n📊 整体统计信息"
echo "Rime词库提取有效词条：$NEW_RIME_COUNT 条"
echo "识别负c待删除词条总数：$BLACK_T_COUNT 条"
echo "繁体子模块基底总行数：$T_SUB_LINES 条"
echo "简体子模块基底总行数：$S_SUB_LINES 条"
echo "词条筛选门槛：单字 c>1(c≥2)；多字 c>0(c≥1)"
echo "时间策略：30天内新词不做衰减；超过30天才缓慢衰减；c频次主导权重，时间仅微调分数，不删除词条"
echo "子模块更新策略：30天内仅拉取一次，标记文件 .submodule_last_update.stamp"
echo "分数分层规则："
echo "  1.7天内短时阻尼抑制权重爆炸；满30天才开启衰减，衰减下限0.7，弱化时间对分数影响"
echo "  2.全部来源（子模块/旧输出库/rime用户库）统一前置钳位，输出强制：43 ≤ 权重 ≤3890"
echo "  3.存量词库与新词条同key保留权重较大值；子模块增删改同步到最终输出词库；"
echo "黑名单策略：空黑名单直接跳过过滤，彻底杜绝词库清空"

echo -e "\n🔍 Rime新增词条均匀采样样例（最多15条）"
echo -e "\n===== 写入繁体库原文 ====="
sample_entries "$NEW_RAW_RIME" 15
echo -e "\n===== 转换后写入简体库 ====="
sample_entries "$NEW_SIMP_RIME" 15

echo -e "\n🎉 全部处理流程结束"
