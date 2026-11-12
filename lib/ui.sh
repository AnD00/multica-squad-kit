# セットアップの画面の色を一か所で決める。bash 3.2 で動かす。
# 色の種類と範囲は manual.md の「表示の色と印」に従う。色の制御文字は、この
# ファイルの関数だけが作る。

ui_color_out=no
ui_color_err=no
ui_live_out=no
ui_live_err=no

# 種類ごとの「太字か（1 か 0）」と「xterm の 256 色の番号」。色を付けない種類は -。
ui_kinds='question active strong description choice default success warning error done'
ui_spec() {
	case $1 in
	question) printf '%s\n' '1 32' ;;
	active) printf '%s\n' '0 32' ;;
	strong) printf '%s\n' '1 -' ;;
	description) printf '%s\n' '0 -' ;;
	choice) printf '%s\n' '1 98' ;;
	default) printf '%s\n' '0 244' ;;
	success) printf '%s\n' '0 28' ;;
	warning) printf '%s\n' '1 166' ;;
	error) printf '%s\n' '1 196' ;;
	done) printf '%s\n' '1 30' ;;
	*) return 1 ;;
	esac
}

# 出す先ごとに、色を付けるかを一度だけ決める。標準出力と標準エラー出力は別に
# 判定し、結果を ui_color_out と ui_color_err（yes か no）に置く。行を書き換えてよいかは、
# 出す先が端末で色が出るときだけ yes とし、ui_live_out と ui_live_err に置く。
ui_init() {
	local colors
	ui_color_out=no
	ui_color_err=no
	ui_live_out=no
	ui_live_err=no
	[[ -z ${NO_COLOR+x} ]] || return 0
	case ${TERM:-} in '' | dumb) return 0 ;; esac
	colors=$(tput colors 2>/dev/null) || return 0
	[[ $colors =~ ^[0-9]+$ ]] && ((colors >= 256)) || return 0
	if [[ -t 1 ]]; then ui_color_out=yes; ui_live_out=yes; fi
	if [[ -t 2 ]]; then ui_color_err=yes; ui_live_err=yes; fi
	return 0
}

# ui_paint <out|err> <種類> <文字>: 文字を、その出す先の判定どおりに色を付けて
# 改行なしで出す。色を付けないときは文字だけを出す。
ui_paint() {
	local target=$1 kind=$2 text=$3 spec bold color enabled
	spec=$(ui_spec "$kind") || return 1
	bold=${spec% *}
	color=${spec#* }
	case $target in
	out) enabled=$ui_color_out ;;
	err) enabled=$ui_color_err ;;
	*) return 1 ;;
	esac
	if [[ $enabled != yes || ( $color == - && $bold == 0 ) ]]; then
		printf '%s' "$text"
	elif [[ $color == - ]]; then
		printf '\033[1m%s\033[0m' "$text"
	elif [[ $bold == 1 ]]; then
		printf '\033[1;38;5;%sm%s\033[0m' "$color" "$text"
	else
		printf '\033[38;5;%sm%s\033[0m' "$color" "$text"
	fi
}

# ui_line <out|err> <種類> <文字>: ui_paint の出力に改行を足し、出す先の画面に出す。
ui_line() {
	if [[ $1 == err ]]; then ui_paint "$@" >&2; printf '\n' >&2
	else ui_paint "$@"; printf '\n'; fi
}

# ui_error / ui_warning <文字>: 行頭に印の「エラー:」「警告:」を付けて、標準エラー出力へ行全体を
# 種類の色で出す。印は色の有無によらず同じ文字を出す。
ui_error() { ui_line err error "エラー: $*"; }
ui_warning() { ui_line err warning "警告: $*"; }

# ui_mark <out|err> <印の名前> <本文> [値]: 印と本文、灰の値を一行にする。
# まだの手順と、そのまま使うものは本文も灰にする。
ui_mark() {
	local target=$1 mark=$2 text=$3 value=${4-} symbol kind body=description fd
	case $target in out) fd=1 ;; err) fd=2 ;; *) return 1 ;; esac
	case $mark in
	ok) symbol=✔; kind=success ;;
	fail) symbol=✖; kind=error ;;
	add) symbol=+; kind=success ;;
	change) symbol='~'; kind=description ;;
	keep) symbol=·; kind=default; body=default ;;
	warn) symbol='!'; kind=warning ;;
	drop) symbol=-; kind=default ;;
	todo) symbol=○; kind=default; body=default ;;
	*) return 1 ;;
	esac
	{
		ui_paint "$target" "$kind" "$symbol"
		printf ' '
		ui_paint "$target" "$body" "$text"
		if [[ -n $value ]]; then
			printf '  '
			ui_paint "$target" default "$value"
		fi
		printf '\n'
	} >&$fd
}

# ui_complete <out|err> <名前> [値]: 完了の印と名前を太字の青緑にし、値は既定の色で添える。
ui_complete() {
	local target=$1 text=$2 value=${3-} fd
	case $target in out) fd=1 ;; err) fd=2 ;; *) return 1 ;; esac
	{
		ui_paint "$target" done "✔ $text"
		if [[ -n $value ]]; then printf '  %s' "$value"; fi
		printf '\n'
	} >&$fd
}

# _ui_character <本文> <バイトの位置>: その位置の文字のバイト数と表示の幅を、
# ui_character_bytes と ui_character_width に置く。幅の計算と行を切る処理で共有する。
# 読めないバイトは 1 バイトで幅 1 にし、次のバイトから読み直す。
_ui_character() {
	local LC_ALL=C
	local text=$1 offset=$2 byte code count=1 minimum=0 next part valid=yes i
	printf -v byte '%d' "'${text:offset:1}"
	# bash 3.2 が負の値で返すバイトも、0〜255 にそろえる。
	byte=$((byte & 255))
	code=$byte
	if ((byte >= 194 && byte <= 223)); then
		count=2 code=$((byte & 31)) minimum=128
	elif ((byte >= 224 && byte <= 239)); then
		count=3 code=$((byte & 15)) minimum=2048
	elif ((byte >= 240 && byte <= 244)); then
		count=4 code=$((byte & 7)) minimum=65536
	fi
	for ((i = 1; i < count; i++)); do
		next=$((offset + i))
		if ((next >= ${#text})); then valid=no; break; fi
		printf -v part '%d' "'${text:next:1}"
		part=$((part & 255))
		if ((part < 128 || part > 191)); then valid=no; break; fi
		code=$(((code << 6) | (part & 63)))
	done
	if [[ $valid == no ]] || ((code < minimum || code > 1114111 || (code >= 55296 && code <= 57343))); then
		count=1
	fi
	ui_character_bytes=$count ui_character_width=1
	if ((count == 4 || (count == 3 && (
		(code >= 0x1100 && code <= 0x115f) ||
		(code >= 0x2e80 && code <= 0xa4cf) ||
		(code >= 0xac00 && code <= 0xd7a3) ||
		(code >= 0xf900 && code <= 0xfaff) ||
		(code >= 0xfe30 && code <= 0xfe4f) ||
		(code >= 0xff00 && code <= 0xff60) ||
		(code >= 0xffe0 && code <= 0xffe6))))); then
		ui_character_width=2
	fi
}

# _ui_text_width <本文>: 表示の幅を ui_text_width に置く。コマンド置換を使わずに数える。
_ui_text_width() {
	local LC_ALL=C
	local text=$1 offset=0
	ui_text_width=0
	while ((offset < ${#text})); do
		_ui_character "$text" "$offset"
		ui_text_width=$((ui_text_width + ui_character_width))
		offset=$((offset + ui_character_bytes))
	done
}

# ui_body_line <out|err> <本文>: 本文の左の罫線だけを灰にする。空の行は罫線だけを出す。
ui_body_line() {
	local target=$1 text=$2 fd
	case $target in out) fd=1 ;; err) fd=2 ;; *) return 1 ;; esac
	{
		ui_paint "$target" default '│'
		if [[ -n $text ]]; then printf ' %s' "$text"; fi
		printf '\n'
	} >&$fd
}

# ui_width <本文>: UTF-8 の文字の表示の幅。外の道具や文字ごとの子のプロセスを使わない。
# 読めないバイトは一桁にし、次のバイトから読み直す。
ui_width() {
	_ui_text_width "$1"
	printf '%s\n' "$ui_text_width"
}

# ui_pad <幅> <本文>: 表示の幅をそろえる。長い本文は切らない。
ui_pad() {
	local width=$1 text=$2 size padding
	size=$(ui_width "$text")
	padding=$((width - size))
	if ((padding < 0)); then padding=0; fi
	printf '%s%*s' "$text" "$padding" ''
}

ui_lines=
ui_columns=

# _ui_positive <値>: 正の整数か。
_ui_positive() {
	[[ $1 =~ ^[0-9]+$ ]] && ((10#$1 > 0))
}

# ui_size <out|err>: その出す先の端末の高さと幅を、ui_lines と ui_columns に置く。標準出力には
# 何も出さない。コマンド置換の中で呼ぶと標準出力がパイプになり、out の端末を読めないので、
# 書き換える部品は今のシェルで呼ぶ。出す先の fd を stty の標準入力に渡して読む。macOS の
# tput は、出力をパイプへつなぐと端末の定義の 80 桁・24 行を返すため、先には使わない。
# 読めない値は、行と桁を別々に、tput、LINES と COLUMNS、24 行と 80 桁の順に決める。
ui_size() {
	local size= lines columns
	case ${1-} in
	out) { size=$(stty size <&3 2>/dev/null) || size=; } 3>&1 ;;
	err) { size=$(stty size <&3 2>/dev/null) || size=; } 3>&2 ;;
	*) return 1 ;;
	esac
	lines=${size%% *}
	columns=
	if [[ $size == *' '* ]]; then columns=${size#* }; fi
	if ! _ui_positive "$lines"; then lines=$(tput lines 2>/dev/null) || lines=; fi
	if ! _ui_positive "$lines"; then lines=${LINES-}; fi
	if ! _ui_positive "$lines"; then lines=24; fi
	if ! _ui_positive "$columns"; then columns=$(tput cols 2>/dev/null) || columns=; fi
	if ! _ui_positive "$columns"; then columns=${COLUMNS-}; fi
	if ! _ui_positive "$columns"; then columns=80; fi
	ui_lines=$((10#$lines)) ui_columns=$((10#$columns))
}

# ui_rows <本文>: 本文が端末で占める行の数。表示の幅を、最後に ui_size で読んだ幅で割って
# 切り上げる。まだ読んでいなければ、標準エラー出力の端末で読む。
ui_rows() {
	if [[ -z ${ui_columns-} ]]; then ui_size err; fi
	_ui_text_width "$1"
	printf '%s\n' "$(((ui_text_width + ui_columns - 1) / ui_columns))"
}

# ui_rewind <out|err> <行数>: 出した行を書き換えるために、行数だけ上へ戻って行頭から下を消す。
# 色が出る端末で、呼ぶ側が行を数えたときだけ使う。自分が出した行より上へは戻らない。
ui_rewind() {
	local target=$1 rows=$2
	[[ $rows =~ ^[0-9]+$ ]] && ((rows > 0)) || return 1
	case $target in
	out) printf '\033[%sA\r\033[J' "$rows" ;;
	err) printf '\033[%sA\r\033[J' "$rows" >&2 ;;
	*) return 1 ;;
	esac
}

# チェックリスト。1 つの出す先に出し、一度に一つだけ動かす。呼ぶ側は、終わるときの片付け
# （trap）でも ui_steps_cleanup を呼ぶ。
ui_steps_active=no
ui_steps_live=no
ui_steps_count=0
ui_steps_wait_interval=30
ui_spinner_pid=
ui_steps_dir=
ui_steps_notice_file=
ui_steps_subject=
ui_steps_phase_began=0

ui_steps_cleanup() {
	_ui_spinner_stop
	if [[ -n ${ui_steps_dir:-} ]]; then rm -rf -- "$ui_steps_dir"; fi
	if [[ -n ${ui_steps_notice_file:-} ]]; then rm -f -- "$ui_steps_notice_file" "$ui_steps_notice_file.failed"; fi
	ui_steps_dir= ui_steps_notice_file= ui_steps_active=no ui_steps_live=no
}

_ui_spinner_stop() {
	if [[ -n ${ui_spinner_pid:-} ]]; then
		kill -TERM "$ui_spinner_pid" 2>/dev/null || :
		{ wait "$ui_spinner_pid"; } 2>/dev/null || :
		ui_spinner_pid=
	fi
}

# _ui_steps_clip <色の列を含む行> <幅>: 行を幅に収めて ui_steps_clipped に置く。収まらないときは、
# 色の列を保ち、全角を途中で分けずに切って、灰の … を付けた全体を幅に収める。
_ui_steps_clip() {
	local LC_ALL=C
	local text=$1 limit=$2 rest=$1 plain= offset=0 width=0 chunk budget
	while [[ $rest == *$'\033['* ]]; do
		plain+=${rest%%$'\033['*}
		rest=${rest#*$'\033['}
		rest=${rest#*m}
	done
	plain+=$rest
	_ui_text_width "$plain"
	if ((ui_text_width <= limit)); then ui_steps_clipped=$text; return 0; fi
	budget=$((limit - 1))
	if ((budget < 0)); then budget=0; fi
	ui_steps_clipped=
	while ((offset < ${#text})); do
		if [[ ${text:offset:1} == $'\033' ]]; then
			chunk=${text:offset}
			chunk=${chunk%%m*}m
			ui_steps_clipped+=$chunk
			offset=$((offset + ${#chunk}))
			continue
		fi
		_ui_character "$text" "$offset"
		if ((width + ui_character_width > budget)); then break; fi
		ui_steps_clipped+=${text:offset:ui_character_bytes}
		width=$((width + ui_character_width))
		offset=$((offset + ui_character_bytes))
	done
	ui_steps_clipped+=$'\033[0m'$(ui_paint "$ui_steps_target" default '…')
}

# _ui_steps_time <秒>: 48s、1m12s の形を ui_steps_time_text に置く。
_ui_steps_time() {
	if (($1 < 60)); then ui_steps_time_text="$1s"
	else ui_steps_time_text="$(($1 / 60))m$(($1 % 60))s"; fi
}

# 手順 <番号> の行を、改行なしで標準出力へ出す。
_ui_steps_main() {
	local index=$1 state=${ui_steps_states[$1]} name=${ui_steps_names[$1]} value=${ui_steps_values[$1]}
	local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) filled bar_done= bar_rest= i
	printf '%*s' "$ui_steps_indent" ''
	case $state in
	todo) ui_mark "$ui_steps_target" todo "$name" ;;
	ok | fail)
		if [[ -n $value ]]; then name=${ui_steps_padded[$index]}; fi
		ui_mark "$ui_steps_target" "$state" "$name" "$value"
		;;
	active)
		ui_paint "$ui_steps_target" active "${frames[$((ui_steps_frame % 10))]}"
		if ((ui_steps_total > 0)) || [[ -n $ui_steps_elapsed || -n $ui_steps_subname ]]; then name=${ui_steps_padded[$index]}; fi
		printf ' %s' "$name"
		if ((ui_steps_total > 0)); then
			filled=$((18 * ui_steps_progress / ui_steps_total))
			for ((i = 0; i < 18; i++)); do
				if ((i < filled)); then bar_done+=━; else bar_rest+=─; fi
			done
			printf '  '
			if [[ -n $bar_done ]]; then ui_paint "$ui_steps_target" active "$bar_done"; fi
			if [[ -n $bar_rest ]]; then ui_paint "$ui_steps_target" default "$bar_rest"; fi
			if [[ $ui_steps_hide_count != yes ]]; then ui_paint "$ui_steps_target" default " $ui_steps_progress/$ui_steps_total"; fi
		fi
		if [[ -n $ui_steps_elapsed ]]; then printf '  '; ui_paint "$ui_steps_target" default "$ui_steps_elapsed"; fi
		if [[ -n $ui_steps_subname ]]; then printf '  '; ui_paint "$ui_steps_target" default "$ui_steps_subname"; fi
		printf '\n'
		;;
	esac
}

# 続きの行 <番号> を、手順の名前より 2 桁深く、改行なしで標準出力へ出す。
_ui_steps_extra() {
	local index=$1 mark=${ui_steps_extra_marks[$1]} text=${ui_steps_extra_texts[$1]} value=${ui_steps_extra_values[$1]}
	printf '%*s' "$((ui_steps_indent + 4))" ''
	if [[ $mark != - ]]; then
		ui_mark "$ui_steps_target" "$mark" "$text" "$value"
		return
	fi
	printf '%s' "$text"
	if [[ -n $value ]]; then
		if [[ -n $text ]]; then printf '  '; fi
		ui_paint "$ui_steps_target" default "$value"
	fi
	printf '\n'
}

# ui_steps_buffer に、手順 <番号> の行と続きの行を、切らずに足す。終わった手順の続きの行は、
# 出したことを覚える。
_ui_steps_append_full() {
	local i=$1 j
	ui_steps_text=$(_ui_steps_main "$i" 2>&1)
	ui_steps_buffer+=$ui_steps_text$'\n'
	for ((j = 0; j < ui_steps_extra_count; j++)); do
		((ui_steps_extra_steps[j] == i)) || continue
		ui_steps_text=$(_ui_steps_extra "$j" 2>&1)
		ui_steps_buffer+=$ui_steps_text$'\n'
		if [[ ${ui_steps_states[$i]} == ok || ${ui_steps_states[$i]} == fail ]]; then ui_steps_extra_printed[$j]=yes; fi
	done
}

_ui_steps_append_tail() {
	local i
	for ((i = 0; i < ui_steps_tail_count; i++)); do ui_steps_buffer+=${ui_steps_tail_lines[$i]}$'\n'; done
}

# 書き換える範囲（手順 <番号> から下）の行を、幅から 1 を引いた幅に切って ui_steps_cache に置く。
_ui_steps_build_cache() {
	local i=$1 j k=0
	ui_steps_cache=() ui_steps_cache_active=-1
	for ((; i < ui_steps_count; i++)); do
		if [[ ${ui_steps_states[$i]} == active ]]; then ui_steps_cache_active=$k; fi
		ui_steps_text=$(_ui_steps_main "$i" 2>&1)
		_ui_steps_clip "$ui_steps_text" "$((ui_columns - 1))"
		ui_steps_cache[$k]=$ui_steps_clipped
		k=$((k + 1))
		for ((j = 0; j < ui_steps_extra_count; j++)); do
			((ui_steps_extra_steps[j] == i)) || continue
			ui_steps_text=$(_ui_steps_extra "$j" 2>&1)
			_ui_steps_clip "$ui_steps_text" "$((ui_columns - 1))"
			ui_steps_cache[$k]=$ui_steps_clipped
			k=$((k + 1))
		done
	done
	for ((j = 0; j < ui_steps_tail_count; j++)); do
		_ui_steps_clip "${ui_steps_tail_lines[$j]}" "$((ui_columns - 1))"
		ui_steps_cache[$k]=$ui_steps_clipped
		k=$((k + 1))
	done
	ui_steps_cache_count=$k
}

# ui_steps_rewind に、描いた行の数だけ上へ戻って下を消す制御文字を置く。自分が出した行より
# 上へは戻らない。
_ui_steps_rewind_text() {
	ui_steps_rewind=
	if ((ui_steps_drawn > 0)); then ui_steps_rewind=$'\033['$ui_steps_drawn$'A\r\033[J'; fi
}

_ui_steps_write() {
	if [[ $ui_steps_target == out ]]; then printf '%s' "$1"; else printf '%s' "$1" >&2; fi
}

# 書き換える範囲を描き直す。終わった手順は切らずに出して残し、範囲はまだ終わっていない最初の
# 手順から下にする。大きさが変わったとき、範囲が高さ - 1 を超えるとき、<final> を渡されたとき
# （失敗の描き直し）は、一覧を切らずに 1 回出して、以後は書き換えない。
_ui_steps_refresh() {
	local mode=${1-live} next=$ui_steps_first pending=$ui_steps_tail_count i j changed=no insert=$ui_steps_insert
	ui_steps_insert= ui_steps_flushed=no
	[[ $ui_steps_live == yes ]] || return 0
	ui_size "$ui_steps_target"
	if [[ $ui_columns != "$ui_steps_columns" || $ui_lines != "$ui_steps_lines" ]]; then changed=yes; fi
	if [[ -n $ui_steps_dir && -f $ui_steps_dir/resized ]]; then changed=yes; fi
	while ((next < ui_steps_count)) && [[ ${ui_steps_states[$next]} == ok ]]; do next=$((next + 1)); done
	for ((i = next; i < ui_steps_count; i++)); do
		pending=$((pending + 1))
		for ((j = 0; j < ui_steps_extra_count; j++)); do
			if ((ui_steps_extra_steps[j] == i)); then pending=$((pending + 1)); fi
		done
	done
	_ui_steps_rewind_text
	ui_steps_buffer=
	if [[ $changed == yes || $mode == final ]] || ((pending > ui_lines - 1)); then
		# 大きさが変わると、端末が前の行を折り返し直すので、戻らずにその下へ出す。
		if [[ $changed == yes ]]; then ui_steps_rewind=; fi
		ui_steps_buffer=$ui_steps_rewind$insert
		for ((i = ui_steps_first; i < ui_steps_count; i++)); do _ui_steps_append_full "$i"; done
		_ui_steps_append_tail
		_ui_steps_write "$ui_steps_buffer"
		ui_steps_live=no ui_steps_drawn=0 ui_steps_flushed=yes
		return 0
	fi
	ui_steps_frame=$((ui_steps_frame + 1))
	ui_steps_buffer=$ui_steps_rewind$insert
	for ((i = ui_steps_first; i < next; i++)); do _ui_steps_append_full "$i"; done
	_ui_steps_build_cache "$next"
	for ((i = 0; i < ui_steps_cache_count; i++)); do ui_steps_buffer+=${ui_steps_cache[$i]}$'\n'; done
	_ui_steps_write "$ui_steps_buffer"
	ui_steps_first=$next ui_steps_drawn=$pending
	ui_steps_columns=$ui_columns ui_steps_lines=$ui_lines
}

# 動いている手順の行のスピナーを、0.1 秒ごとに裏で回す。回すたびに大きさを読み、変わっていたら
# 回すのをやめて、表に書き換えをやめさせる印のファイルを置く。
_ui_spinner_start() {
	[[ $ui_steps_live == yes && $ui_steps_active == yes ]] || return 0
	((ui_steps_cache_active >= 0)) || return 0
	local owner=$$
	(
		stop=no ticks=0
		trap 'stop=yes' TERM HUP INT
		while [[ $stop != yes ]]; do
			sleep 0.1
			[[ $stop != yes ]] || break
			kill -0 "$owner" 2>/dev/null || break
			# 親が終わってもまだ受け取られていない（zombie）あいだは kill -0 が通るので、1 秒おきに状態も見る。
			ticks=$((ticks + 1))
			if ((ticks % 10 == 0)); then
				state=$(ps -o stat= -p "$owner" 2>/dev/null) || state=
				[[ $state != Z* ]] || break
			fi
			ui_size "$ui_steps_target"
			if [[ $ui_columns != "$ui_steps_columns" || $ui_lines != "$ui_steps_lines" ]]; then
				if [[ -n $ui_steps_dir ]]; then : >"$ui_steps_dir/resized"; fi
				break
			fi
			ui_steps_frame=$((ui_steps_frame + 1))
			ui_steps_text=$(_ui_steps_main "$ui_steps_current" 2>&1)
			_ui_steps_clip "$ui_steps_text" "$((ui_columns - 1))"
			ui_steps_cache[$ui_steps_cache_active]=$ui_steps_clipped
			_ui_steps_rewind_text
			ui_steps_buffer=$ui_steps_rewind
			for ((i = 0; i < ui_steps_cache_count; i++)); do ui_steps_buffer+=${ui_steps_cache[$i]}$'\n'; done
			_ui_steps_write "$ui_steps_buffer"
		done
	) &
	ui_spinner_pid=$!
}

# ui_steps_begin <out|err> <字下げ> <名前…>: 手順の名前を覚える。書き換えるときは、すべての手順を
# ○ と灰の名前で並べる。書き換えないときは何も出さない。
ui_steps_begin() {
	local i width longest=0
	ui_steps_cleanup
	ui_steps_target=${1-} ui_steps_indent=${2-0}
	case $ui_steps_target in
	out) ui_steps_live=$ui_live_out ;;
	err) ui_steps_live=$ui_live_err ;;
	*) return 1 ;;
	esac
	shift 2
	ui_steps_names=("$@") ui_steps_padded=() ui_steps_states=() ui_steps_values=()
	ui_steps_extra_steps=() ui_steps_extra_marks=() ui_steps_extra_texts=() ui_steps_extra_values=() ui_steps_extra_printed=()
	ui_steps_cache=()
	ui_steps_tail_lines=() ui_steps_tail_count=0 ui_steps_shown_rows=0 ui_steps_shown_columns=0 ui_steps_shown_lines=0
	ui_steps_count=$# ui_steps_extra_count=0 ui_steps_current=0 ui_steps_first=0 ui_steps_drawn=0 ui_steps_frame=0
	ui_steps_cache_active=-1 ui_steps_cache_count=0 ui_steps_insert= ui_steps_flushed=no ui_steps_buffer=
	ui_steps_progress=0 ui_steps_total=0 ui_steps_elapsed= ui_steps_subname= ui_steps_last_wait=0 ui_steps_hide_count=no
	for ((i = 0; i < ui_steps_count; i++)); do
		_ui_text_width "${ui_steps_names[$i]}"
		if ((ui_text_width > longest)); then longest=$ui_text_width; fi
	done
	for ((i = 0; i < ui_steps_count; i++)); do
		ui_steps_states[$i]=todo ui_steps_values[$i]=
		ui_steps_padded[$i]=$(ui_pad "$longest" "${ui_steps_names[$i]}")
	done
	ui_steps_active=yes
	if [[ $ui_steps_live == yes ]]; then
		ui_steps_dir=$(mktemp -d "${TMPDIR:-/tmp}/squad-ui.XXXXXX" 2>/dev/null) || ui_steps_dir=
		ui_size "$ui_steps_target"
		ui_steps_columns=$ui_columns ui_steps_lines=$ui_lines
		_ui_steps_refresh
	fi
}

# ui_steps_show: 書き換えるかによらず、今の一覧を出す。
ui_steps_show() {
	local i line rest
	_ui_spinner_stop
	if [[ $ui_steps_live == yes ]]; then
		_ui_steps_refresh
		_ui_spinner_start
		return 0
	fi
	ui_steps_buffer=
	for ((i = 0; i < ui_steps_count; i++)); do _ui_steps_append_full "$i"; done
	_ui_steps_append_tail
	_ui_steps_write "$ui_steps_buffer"
	# 切らずに出した行の数と大きさを覚え、問いを含む範囲の書き換えに備える。
	ui_size "$ui_steps_target"
	ui_steps_shown_columns=$ui_columns ui_steps_shown_lines=$ui_lines ui_steps_shown_rows=0
	rest=$ui_steps_buffer
	while [[ -n $rest ]]; do
		line=${rest%%$'\n'*}; rest=${rest#*$'\n'}
		_ui_steps_clip "$line" 2147483647
		ui_steps_shown_rows=$((ui_steps_shown_rows + (ui_text_width + ui_columns - 1) / ui_columns))
		if ((ui_text_width == 0)); then ui_steps_shown_rows=$((ui_steps_shown_rows + 1)); fi
	done
}

# ui_steps_tail <出した文字>: ui_steps_show のあと、一覧の下に出した空行や答えた問いを覚える。
# 文字を出さず、次の手順から同じ一覧を更新できるようにする。最後には改行を含める。
# 出した範囲が流れたときや、その間にリサイズされたときは戻らない。
ui_steps_tail() {
	local rest=$1 line rows=$ui_steps_shown_rows capable
	_ui_spinner_stop
	ui_steps_tail_lines=() ui_steps_tail_count=0
	ui_size "$ui_steps_target"
	while [[ -n $rest ]]; do
		line=${rest%%$'\n'*}
		if [[ $rest == *$'\n'* ]]; then rest=${rest#*$'\n'}; else rest=; fi
		ui_steps_tail_lines[$ui_steps_tail_count]=$line
		ui_steps_tail_count=$((ui_steps_tail_count + 1))
		_ui_steps_clip "$line" 2147483647
		rows=$((rows + (ui_text_width + ui_columns - 1) / ui_columns))
		if ((ui_text_width == 0)); then rows=$((rows + 1)); fi
	done
	case $ui_steps_target in out) capable=$ui_live_out ;; err) capable=$ui_live_err ;; esac
	if [[ $capable != yes || $ui_steps_shown_columns != "$ui_columns" || $ui_steps_shown_lines != "$ui_lines" ]] || ((rows > ui_lines - 1)); then
		ui_steps_live=no
		return 0
	fi
	ui_steps_live=yes ui_steps_drawn=$rows ui_steps_columns=$ui_columns ui_steps_lines=$ui_lines
	if [[ -z $ui_steps_dir ]]; then ui_steps_dir=$(mktemp -d "${TMPDIR:-/tmp}/squad-ui.XXXXXX" 2>/dev/null) || ui_steps_dir=; fi
}

ui_step_start() {
	_ui_spinner_stop
	ui_steps_current=$(($1 - 1))
	((ui_steps_current >= 0 && ui_steps_current < ui_steps_count)) || return 1
	ui_steps_states[$ui_steps_current]=active
	ui_steps_progress=0 ui_steps_total=0 ui_steps_elapsed= ui_steps_subname= ui_steps_last_wait=0 ui_steps_hide_count=no
	_ui_steps_refresh
	_ui_spinner_start
}

# ui_step_progress <済んだ数> <全体の数> [名前] [nocount]: ゲージを描く。4 つ目に nocount を渡すと、
# ゲージのあとの「済んだ数/全体の数」を出さない（数を読めても、画面に出したくないとき）。
ui_step_progress() {
	_ui_spinner_stop
	ui_steps_progress=$1 ui_steps_total=$2 ui_steps_subname=${3-} ui_steps_hide_count=no
	if [[ ${4-} == nocount ]]; then ui_steps_hide_count=yes; fi
	if ((ui_steps_progress < 0)); then ui_steps_progress=0; fi
	if ((ui_steps_progress > ui_steps_total)); then ui_steps_progress=$ui_steps_total; fi
	_ui_steps_refresh
	_ui_spinner_start
}

# ui_step_wait <経過の秒>: 書き換えないときは、ui_steps_wait_interval 秒ごとに 1 行だけ足す。
ui_step_wait() {
	_ui_spinner_stop
	_ui_steps_time "$1"
	ui_steps_elapsed=$ui_steps_time_text
	_ui_steps_refresh
	if [[ $ui_steps_live == no && $ui_steps_flushed == no ]] && (($1 - ui_steps_last_wait >= ui_steps_wait_interval)); then
		ui_steps_text=$(printf '%*s' "$ui_steps_indent" ''; ui_paint "$ui_steps_target" default "… ${ui_steps_names[$ui_steps_current]}  $ui_steps_elapsed")
		_ui_steps_write "$ui_steps_text"$'\n'
		ui_steps_last_wait=$1
	fi
	_ui_spinner_start
}

# 書き換えないときに、今の手順の行と、まだ出していない続きの行を順に出す。
_ui_steps_plain_done() {
	local j
	ui_steps_buffer=
	ui_steps_text=$(_ui_steps_main "$ui_steps_current" 2>&1)
	ui_steps_buffer+=$ui_steps_text$'\n'
	for ((j = 0; j < ui_steps_extra_count; j++)); do
		if ((ui_steps_extra_steps[j] == ui_steps_current)) && [[ ${ui_steps_extra_printed[$j]} == no ]]; then
			ui_steps_text=$(_ui_steps_extra "$j" 2>&1)
			ui_steps_buffer+=$ui_steps_text$'\n'
			ui_steps_extra_printed[$j]=yes
		fi
	done
	_ui_steps_write "$ui_steps_buffer"
}

# ui_step_done <値>
ui_step_done() {
	_ui_spinner_stop
	ui_steps_states[$ui_steps_current]=ok ui_steps_values[$ui_steps_current]=${1-}
	_ui_steps_refresh
	if [[ $ui_steps_live == no && $ui_steps_flushed == no ]]; then _ui_steps_plain_done; fi
}

# ui_step_fail [名前]: 動いている手順を ✖ にして、以後は書き換えない。
ui_step_fail() {
	_ui_spinner_stop
	ui_steps_states[$ui_steps_current]=fail ui_steps_values[$ui_steps_current]=${1-}
	_ui_steps_refresh final
	if [[ $ui_steps_live == no && $ui_steps_flushed == no ]]; then _ui_steps_plain_done; fi
	ui_steps_live=no ui_steps_drawn=0
}

# ui_step_line <印|-> <本文> [値]: 今の手順の行の下に続きの行を足す。
ui_step_line() {
	local index=$ui_steps_extra_count
	_ui_spinner_stop
	ui_steps_extra_steps[$index]=$ui_steps_current ui_steps_extra_marks[$index]=$1
	ui_steps_extra_texts[$index]=$2 ui_steps_extra_values[$index]=${3-} ui_steps_extra_printed[$index]=no
	ui_steps_extra_count=$((index + 1))
	if [[ $ui_steps_live == yes && $ui_steps_current -lt $ui_steps_first ]]; then
		# 終わって画面に残した手順の下に足すので、範囲を戻したところへ、切らずに出す。
		ui_steps_text=$(_ui_steps_extra "$index" 2>&1)
		ui_steps_insert=$ui_steps_text$'\n'
		ui_steps_extra_printed[$index]=yes
		_ui_steps_refresh
	elif [[ $ui_steps_live == yes ]]; then
		_ui_steps_refresh
	elif [[ ${ui_steps_states[$ui_steps_current]} != active && ${ui_steps_states[$ui_steps_current]} != todo ]]; then
		ui_steps_text=$(_ui_steps_extra "$index" 2>&1)
		_ui_steps_write "$ui_steps_text"$'\n'
		ui_steps_extra_printed[$index]=yes
	fi
	_ui_spinner_start
}

# 子のプロセス（サブシェル）の中の通知を、一覧を動かしている親へ渡す。子は一覧の状態を書き換えても親へ戻せない
# ので、続きの行は置き場のファイルに 1 行ずつ足し、親が手順を終えるときに ui_step_line で出す。
# ui_steps_notice_file に置き場を決めて呼ぶ。決めないときは、動いている手順に続きの行として足す。

# ui_notice <印|-> <本文> [値]: 一覧が動いていれば、続きの行を置き場に足して 0 を返す。動いていないときは
# 何もせず 1 を返すので、呼ぶ側は今までの表示に戻す。
ui_notice() {
	[[ ${ui_steps_active:-no} == yes ]] || return 1
	if [[ -n ${ui_steps_notice_file:-} ]]; then
		printf '%s\t%s\t%s\n' "$1" "$2" "${3-}" >>"$ui_steps_notice_file" || return 1
	else
		ui_step_line "$@"
	fi
}

# ui_notice_flush: 置き場にたまった続きの行を、今の手順の下へ順に出して、置き場を空にする。
ui_notice_flush() {
	local mark text value
	[[ ${ui_steps_active:-no} == yes && -n ${ui_steps_notice_file:-} && -s $ui_steps_notice_file ]] || return 0
	while IFS=$'\t' read -r mark text value || [[ -n $mark ]]; do
		ui_step_line "$mark" "$text" "$value"
	done <"$ui_steps_notice_file"
	: >"$ui_steps_notice_file"
}

# 次の ui_phase_* は、一覧が動いていないときは何もしない。一覧の外から呼ばれる関数が、今までの表示のまま動くため。
# ui_phase_start <番号>: その手順を動かす。扱う名前は空にする。
ui_phase_start() {
	[[ ${ui_steps_active:-no} == yes ]] || return 0
	ui_steps_subject=
	ui_steps_phase_began=$SECONDS
	ui_step_start "$1"
}

# ui_phase_active: 作る間の一覧が動いていれば真。偽のときは、呼ぶ側が今までの表示を出す。
ui_phase_active() { [[ ${ui_steps_active:-no} == yes ]]; }

# ui_phase_progress <済んだ数> <全体の数> [名前]: 動いている手順のゲージを進め、名前を扱う名前として覚える。
ui_phase_progress() {
	[[ ${ui_steps_active:-no} == yes ]] || return 0
	ui_steps_subject=${3-}
	ui_step_progress "$1" "$2" "${3-}"
}

# ui_phase_subject <名前>: 扱っている名前を覚える。失敗したときの ✖ の行に灰で添える。
ui_phase_subject() {
	[[ ${ui_steps_active:-no} == yes ]] || return 0
	ui_steps_subject=${1-}
}

# ui_phase_done [値]: たまった続きの行を出してから、動いている手順を ✔ にする。
ui_phase_done() {
	[[ ${ui_steps_active:-no} == yes ]] || return 0
	ui_notice_flush
	ui_steps_subject=
	ui_step_done "${1-}"
}

# ui_phase_done_counted <件数>: 件数と、手順を始めてからの時間（48s、1m12s の形）を値にして、ui_phase_done と同じに終える。
ui_phase_done_counted() {
	[[ ${ui_steps_active:-no} == yes ]] || return 0
	_ui_steps_time "$((SECONDS - ${ui_steps_phase_began:-$SECONDS}))"
	ui_phase_done "$1  $ui_steps_time_text"
}

# ui_phase_fail [名前]: たまった続きの行を出してから、動いている手順を ✖ にする。名前がなければ、扱っていた名前を添える。
# 動いている手順がないときは何もしない。
# 子のプロセスが先に ✖ にして止まったときは、親が続けて呼んでも、一覧を描き直さない（置き場の隣の印で知る）。
ui_phase_fail() {
	[[ ${ui_steps_active:-no} == yes && ${ui_steps_states[$ui_steps_current]:-} == active ]] || return 0
	if [[ -n ${ui_steps_notice_file:-} ]]; then
		[[ ! -e $ui_steps_notice_file.failed ]] || return 0
		: >"$ui_steps_notice_file.failed"
	fi
	ui_notice_flush
	ui_step_fail "${1:-$ui_steps_subject}"
}

# ui_result <結果の語>: 完了の表示の結果の語に、種類の色を付けて改行なしで標準出力へ出す。
# 「成功（HTTP 200）」のように括弧で補足が続くときは、括弧の前の語だけに色を付ける。
# 知らない語は色を付けずに出す。
ui_result() {
	local word=${1%%（*} kind
	case $word in
	一致 | 作成 | 既存 | 新規 | 成功) kind=success ;;
	要確認 | 飛ばした | 記録なし) kind=warning ;;
	失敗) kind=error ;;
	*) printf '%s' "$1"; return 0 ;;
	esac
	ui_paint out "$kind" "$word"
	printf '%s' "${1#"$word"}"
}
