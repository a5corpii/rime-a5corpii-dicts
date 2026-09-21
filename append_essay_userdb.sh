#!/bin/bash
set -o errexit
# 关闭nounset，规避trap提前触发时报未绑定变量

# ==============================================================================
# Rime 用户词库合并导出脚本
# 输出格式 essay-*.txt：字词\t权重，Tab分隔，权重强制锁定 [43, 3890]
# 本次更新改动说明：
# 1.长期衰减下限从0.7上调至0.72，最低保留峰值0.72倍，超过120天后不再继续衰减
# 2.黑名单规则变更：
#    词条c<0时：
#      若词条存在于上游基底词库（essay.txt / dict.yaml来源），保留词条，不删除；
#      不属于基底词库、c<0的用户自造词条，进入黑名单，最终剔除。
# 3.衰减计算机制不变：每次执行脚本基于词条t_val与当前时间一次性计算总衰减，多次执行脚本不会重复叠加衰减
# 4.子模块冷却规则：记录上次成功拉取时间戳，满30天才允许再次拉取，未到期多次执行仅跳过拉取，不修改时间戳
# ==============================================================================

# -------------------------- 全局变量定义区 --------------------------
# Rime配置文件，读取installation_id
RIME_Instl="$HOME/.local/share/fcitx5/rime/installation.yaml"
# 输出词库路径
EssayHanT="./essay-a5corpii.txt"
EssayHanS="./essay-hans-a5corpii.txt"
# 繁体子模块路径
SUBMOD_T_DIR="./rime-essay"
SUBMOD_T_BASE="${SUBMOD_T_DIR}/essay.txt"
# 简体子模块路径
SUBMOD_S_DIR="./rime-essay-simp"
SUBMOD_S_BASE="${SUBMOD_S_DIR}/essay-zh-hans.txt"
# 黑名单临时文件
BLACKLIST_TMP_T="./.blacklist_t.tmp"
BLACKLIST_TMP_S="./.blacklist_s.tmp"
# 子模块标记文件：仅存储【上次成功拉取子模块的Unix时间戳】
SUBMODULE_LAST_PULL_STAMP="./.submodule_last_pull.stamp"
# 子模块拉取冷却周期：30天，单位秒
PULL_COOLDOWN_SEC=$((30 * 24 * 86400))
SEVEN_DAY_SEC=$((7 * 24 * 86400))
# 权重上下限
MAX_SCORE=3890
MIN_BASE_SCORE=43
# 词条筛选阈值
SINGLE_C_THRESHOLD=1
MULTI_C_THRESHOLD=0
# 【修改点】长期衰减下限调整为0.72
DECAY_FLOOR=0.72

# -------------------------- 清理钩子函数 --------------------------
# 只做兜底清理，不读取业务变量，避免变量未定义报错
cleanup() {
    rm -f .tmp .*.XXXXXX.tmp *.preclip .merge_all.tmp .merge_max.tmp
    rm -f "$BLACKLIST_TMP_T" "$BLACKLIST_TMP_S"
    echo -e "\n🧹 兜底清理完成"
}
# 注册trap，全局变量全部定义完成后再注册
trap cleanup EXIT SIGINT SIGTERM SIGQUIT

# -------------------------- 前置依赖检查 --------------------------
check_deps() {
    local dep_list=("awk" "sed" "grep" "opencc" "git")
    for cmd in "${dep_list[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "❌ 缺少依赖工具：$cmd，请先安装"
            exit 1
        fi
    done
    if [ ! -f "$RIME_Instl" ]; then
        echo "❌ 找不到Rime配置文件：$RIME_Instl，请确认fcitx5-rime正常部署"
        exit 1
    fi
}

# -------------------------- 工具函数 --------------------------
## count_lines
# 作用：安全统计文件行数，文件不存在返回0
# $1：文件路径
count_lines() {
    local f="$1"
    if [ -f "$f" ]; then
        wc -l < "$f"
    else
        echo 0
    fi
}

## update_all_submodules
# 子模块拉取冷却逻辑
# 规则：
# 1.读取标记文件，获取上次成功拉取的时间戳；无标记文件=从未拉取，直接执行拉取
# 2.计算：允许下次拉取的时间 = 上次拉取时间 + 30天
# 3.当前时间 < 允许下次拉取时间 → 跳过拉取，标记文件保持原样不变
# 4.当前时间 ≥ 允许下次拉取时间 → 执行git submodule update --remote拉取
# 5.只有拉取命令执行成功之后，才把本次当前时间写入标记文件，更新冷却起点
update_all_submodules() {
    local now=$(date +%s)
    local last_pull_ts=0

    # 读取上次成功拉取的时间戳（标记文件存在时）
    if [ -f "$SUBMODULE_LAST_PULL_STAMP" ]; then
        last_pull_ts=$(< "$SUBMODULE_LAST_PULL_STAMP")
    fi

    # 计算下一次允许拉取的时间点
    local next_allow_pull=$(( last_pull_ts + PULL_COOLDOWN_SEC ))

    echo -e "\nℹ️ 上次子模块拉取时间戳：$last_pull_ts；下次允许拉取时间戳：$next_allow_pull"

    if [ "$now" -lt "$next_allow_pull" ]; then
        echo "✅ 距离上次拉取不足30天，跳过子模块拉取，标记文件不修改"
        return 0
    fi

    # 进入此分支：冷却周期到期，执行拉取
    echo -e "\n🌐 冷却周期已满，执行子模块远程更新..."
    git submodule update --remote "$SUBMOD_T_DIR" >/dev/null 2>&1
    git submodule update --remote "$SUBMOD_S_DIR" >/dev/null 2>&1

    # 拉取成功，把【本次执行时间】写入标记文件，作为新一轮冷却起点
    echo "$now" > "$SUBMODULE_LAST_PULL_STAMP"
    echo "✅ 子模块拉取完成，已更新上次拉取时间戳为 $now"
}

## gen_blacklist
# 【重写黑名单生成函数】
# 参数：$1 userdb路径；$2 基底词库路径；$3 输出黑名单文件
# 逻辑：
# 1.读取基底词库，把所有词条存入awk哈希集合base_dict
# 2.遍历userdb，解析词条、c值
# 3.c<0，且词条不在基底集合内 → 写入黑名单；其余c<0词条保留不拉黑
gen_blacklist() {
    local db_path="$1"
    local base_txt="$2"
    local out_bl="$3"
    awk -F'\t' -v basefile="$base_txt" '
    BEGIN{
        # 加载基底词库全部词条到哈希
        while( (getline line < basefile) >0 ){
            if(line ~ /^#/ || line == "") continue;
            split(line, arr, "\t");
            word = arr[1];
            base_dict[word] = 1;
        }
        close(basefile);
    }
    /^#/{next}
    NF<3{next}
    {
        word = $2;
        split($3, arr, " ");
        c = substr(arr[1],3)+0;
        if(c < 0){
            # c<0，并且不在基底词库 → 加入黑名单
            if( ! (word in base_dict) ){
                print word;
            }
        }
    }' "$db_path" > "$out_bl"
}

## sample_entries
# 作用：均匀采样文本，用于脚本末尾预览词条样例
# $1：输入文本流；$2：最多采样条数
sample_entries() {
    local stream="$1"
    local target="$2"
    echo "$stream" | awk -v N="$target" '
    {lines[NR]=$0; total=NR}
    END{
        if(total==0) exit;
        take = (total < N) ? total : N;
        for(i=0;i<take;i++){
            pos = int(total*i/take)+1;
            print lines[pos];
        }
    }'
}

## extract_valid_rime_words
# 作用：解析userdb，按规则筛选词条，计算原始权重分数
# $1：userdb路径
extract_valid_rime_words() {
    local db_path="$1"
    local now_ts=$(date +%s)
    awk -F'\t' \
        -v now="$now_ts" \
        -v month_sec="$PULL_COOLDOWN_SEC" \
        -v seven_sec="$SEVEN_DAY_SEC" \
        -v s_c_thr="$SINGLE_C_THRESHOLD" \
        -v m_c_thr="$MULTI_C_THRESHOLD" \
        -v decay_floor="$DECAY_FLOOR" '
    {
        word = $2;
        wlen = length(word);
        split($3, field_arr, " ");
        c_val = substr(field_arr[1],3)+0;
        d_val = substr(field_arr[2],3)+0;
        t_val = 0;
        for(f in field_arr){
            if(field_arr[f] ~ /^t=/) t_val = substr(field_arr[f],3)+0;
        }
        # 仅保留纯汉字词条
        if(word !~ /^[\u4E00-\u2A6DF]+$/) next;
        keep=0;
        if(wlen ==1){
            if(c_val > s_c_thr) keep=1;
        }else{
            if(c_val > m_c_thr) keep=1;
        }
        if(keep==0) next;
        delta_t = now - t_val;
        if(delta_t <0) delta_t=0;
        # 7天短时阻尼
        local_damp = 1.0;
        if(delta_t < seven_sec){
            local_damp = 0.4 + 0.6*(delta_t/seven_sec);
        }
        # 长期衰减【修改：下限改为0.72】
        decay_factor = 1.0 - 0.20 * ((delta_t - month_sec)/(3.0*month_sec));
        if(decay_factor < decay_floor) decay_factor = decay_floor;

        c_compress = log(c_val+1);
        len_bonus = 1 + (wlen -2)*0.12;
        raw_final = c_compress * d_val * len_bonus * local_damp * decay_factor;
        score = int(log(raw_final + 1)*120);
        print word "\t" score;
    }' "$db_path"
}

## clip_max_score
# 作用：权重钳位，强制限制在[min,max]
# stdin：字词\t原始分数；stdout：钳位后结果
# $1:max $2:min
clip_max_score() {
    local limit="$1"
    local min="$2"
    awk -F'\t' -v max="$limit" -v min="$min" '
    {
        w=$1; val=$2+0;
        if(NF<2 || val < min) val=min;
        if(val>max) val=max;
        printf("%s\t%d\n",w,val);
    }'
}

## merge_stream_dedup
# 作用：三路词库合并、去重、黑名单过滤、权重钳位
# $1 submod_file 基底词库
# $2 output_file 最终输出文件
# $3 rime_stream rime用户词条流
# $4 bl_file 黑名单文件
# $5 tmp_out 临时输出文件
merge_stream_dedup() {
    local submod_file="$1"
    local output_file="$2"
    local rime_stream="$3"
    local bl_file="$4"
    local tmp_out="$5"

    local clip_submod
    clip_submod=$(mktemp .submod_clip.XXXXXX.tmp)
    local clip_user
    clip_user=$(mktemp .user_clip.XXXXXX.tmp)
    local clip_rime
    clip_rime=$(mktemp .rime_clip.XXXXXX.tmp)

    # 基底词库钳位
    clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" < "$submod_file" > "$clip_submod"
    # 旧词库
    if [ -f "$output_file" ];then
        clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" < "$output_file" > "$clip_user"
    else
        touch "$clip_user"
    fi
    # Rime用户词条流
    echo "$rime_stream" | clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" > "$clip_rime"

    # 合并三路
    {
        cat "$clip_submod"
        cat "$clip_user"
        cat "$clip_rime"
    } > .merge_all.tmp

    # 去重，同词条保留最大权重
    awk -F'\t' '
    NF>=2 && $2~/^[0-9]+$/ {
        if( !max[$1] || $2>max[$1] ) max[$1]=$2
    }
    END{for(k in max) print k"\t"max[k]}
    ' .merge_all.tmp > .merge_max.tmp

    # 黑名单过滤
    local bl_cnt
    bl_cnt=$(count_lines "$bl_file")
    if [ "$bl_cnt" -gt 0 ] && [ "$bl_cnt" -ne 0 ];then
        grep -v -f "$bl_file" .merge_max.tmp | sort -k1,1 > "$tmp_out"
    else
        sort -k1,1 .merge_max.tmp > "$tmp_out"
    fi

    # 二次兜底钳位
    mv "$tmp_out" "${tmp_out}.preclip"
    clip_max_score "$MAX_SCORE" "$MIN_BASE_SCORE" < "${tmp_out}.preclip" > "$tmp_out"
    rm -f "${tmp_out}.preclip"

    # 函数内部清理临时文件
    rm -f "$clip_submod" "$clip_user" "$clip_rime" .merge_all.tmp .merge_max.tmp
    mv -f "$tmp_out" "$output_file"
}

# ====================== 主执行流程 ======================
main() {
    # 前置检查
    check_deps
    # 更新子模块（冷却逻辑完全匹配需求）
    update_all_submodules

    # 读取installation_id
    local INSTALL_ID
    INSTALL_ID=$(grep 'installation_id:' "$RIME_Instl" | sed 's/.*installation_id:\s*//')
    local RIME_DB
    RIME_DB="$HOME/.local/share/fcitx5/rime/sync/${INSTALL_ID}/terra_pinyin.userdb.txt"

    echo -e "\n📌 Rime环境信息"
    echo "installation_id: $INSTALL_ID"
    echo "用户数据库路径: $RIME_DB"

    # 【修改点】生成黑名单：c<0且不在基底词库才拉黑
    echo -e "\n🔍 生成黑名单：仅c<0且不属于基底词库的词条被剔除"
    gen_blacklist "$RIME_DB" "$SUBMOD_T_BASE" "$BLACKLIST_TMP_T"
    # 简体黑名单：使用简体基底词库比对
    gen_blacklist "$RIME_DB" "$SUBMOD_S_BASE" "$BLACKLIST_TMP_S"
    local BLACK_T_COUNT
    BLACK_T_COUNT=$(count_lines "$BLACKLIST_TMP_T")
    echo "本次黑名单待剔除词条总数：$BLACK_T_COUNT"

    # 解析用户词库，得到繁体词条流
    local NEW_RAW_RIME
    NEW_RAW_RIME=$(extract_valid_rime_words "$RIME_DB")
    local NEW_RIME_COUNT
    NEW_RIME_COUNT=$(echo "$NEW_RAW_RIME" | wc -l)
    local NEW_SIMP_RIME
    NEW_SIMP_RIME=$(echo "$NEW_RAW_RIME" | opencc -c t2s.json)

    # 处理繁体词库
    echo -e "\n===== 处理繁体词库 ====="
    local T_OLD
    T_OLD=$(count_lines "$EssayHanT")
    merge_stream_dedup "$SUBMOD_T_BASE" "$EssayHanT" "$NEW_RAW_RIME" "$BLACKLIST_TMP_T" "${EssayHanT}.tmp"
    local T_NEW
    T_NEW=$(count_lines "$EssayHanT")
    local T_SUB_LINES
    T_SUB_LINES=$(count_lines "$SUBMOD_T_BASE")
    local T_DEL
    T_DEL=$(( T_SUB_LINES + T_OLD + NEW_RIME_COUNT - T_NEW ))
    echo "✅ 繁体库：$T_OLD → $T_NEW 行，预估剔除 $T_DEL 条"

    # 处理简体词库
    echo -e "\n===== 处理简体词库 ====="
    local S_OLD
    S_OLD=$(count_lines "$EssayHanS")
    merge_stream_dedup "$SUBMOD_S_BASE" "$EssayHanS" "$NEW_SIMP_RIME" "$BLACKLIST_TMP_S" "${EssayHanS}.tmp"
    local S_NEW
    S_NEW=$(count_lines "$EssayHanS")
    local S_SUB_LINES
    S_SUB_LINES=$(count_lines "$SUBMOD_S_BASE")
    local S_DEL
    S_DEL=$(( S_SUB_LINES + S_OLD + NEW_RIME_COUNT - S_NEW ))
    echo "✅ 简体库：$S_OLD → $S_NEW 行，预估剔除 $S_DEL 条"

    # 统计与采样预览
    echo -e "\n📊 汇总统计"
    echo "Rime提取有效词条: $NEW_RIME_COUNT"
    echo "黑名单待剔除词条: $BLACK_T_COUNT"
    echo "权重强制区间：43 ~ 3890；长期衰减下限锁定0.72"

    echo -e "\n🔍 词条采样预览（最多15条）"
    echo -e "\n---繁体词条样例---"
    sample_entries "$NEW_RAW_RIME" 15
    echo -e "\n---简体词条样例---"
    sample_entries "$NEW_SIMP_RIME" 15

    echo -e "\n🎉 全部流程执行完毕！"
}

# 启动主函数
main
