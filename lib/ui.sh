# セットアップの画面の色を一か所で決める。bash 3.2 で動かす。
# 色の種類と範囲は manual.md の「表示の色と印」に従う。色の制御文字は、この
# ファイルの関数だけが作る。

ui_color_out=no
ui_color_err=no

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
# 判定し、結果を ui_color_out と ui_color_err（yes か no）に置く。
ui_init() {
	local colors
	ui_color_out=no
	ui_color_err=no
	[[ -z ${NO_COLOR+x} ]] || return 0
	case ${TERM:-} in '' | dumb) return 0 ;; esac
	colors=$(tput colors 2>/dev/null) || return 0
	[[ $colors =~ ^[0-9]+$ ]] && ((colors >= 256)) || return 0
	if [[ -t 1 ]]; then ui_color_out=yes; fi
	if [[ -t 2 ]]; then ui_color_err=yes; fi
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

# ui_width <本文>: UTF-8 の文字の表示の幅。外の道具や文字ごとの子のプロセスを使わない。
# 読めないバイトは一桁にし、次のバイトから読み直す。
ui_width() {
	local LC_ALL=C
	local text=$1 offset=0 width=0 byte code count next part valid minimum i
	while ((offset < ${#text})); do
		printf -v byte '%d' "'${text:offset:1}"
		# bash 3.2 が負の値で返すバイトも、0〜255 にそろえる。
		byte=$((byte & 255))
		code=$byte count=1 minimum=0
		if ((byte >= 194 && byte <= 223)); then
			count=2 code=$((byte & 31)) minimum=128
		elif ((byte >= 224 && byte <= 239)); then
			count=3 code=$((byte & 15)) minimum=2048
		elif ((byte >= 240 && byte <= 244)); then
			count=4 code=$((byte & 7)) minimum=65536
		fi
		valid=yes
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
		if ((count == 4 || (count == 3 && (
			(code >= 0x1100 && code <= 0x115f) ||
			(code >= 0x2e80 && code <= 0xa4cf) ||
			(code >= 0xac00 && code <= 0xd7a3) ||
			(code >= 0xf900 && code <= 0xfaff) ||
			(code >= 0xfe30 && code <= 0xfe4f) ||
			(code >= 0xff00 && code <= 0xff60) ||
			(code >= 0xffe0 && code <= 0xffe6))))); then
			width=$((width + 2))
		else
			width=$((width + 1))
		fi
		offset=$((offset + count))
	done
	printf '%s\n' "$width"
}

# ui_pad <幅> <本文>: 表示の幅をそろえる。長い本文は切らない。
ui_pad() {
	local width=$1 text=$2 size padding
	size=$(ui_width "$text")
	padding=$((width - size))
	if ((padding < 0)); then padding=0; fi
	printf '%s%*s' "$text" "$padding" ''
}

# ui_rows <本文>: 端末の幅で折り返す行の数。幅が取れないときは COLUMNS、次に 80。
ui_rows() {
	local text=$1 columns width
	columns=$(tput cols 2>/dev/null) || columns=
	if [[ ! $columns =~ ^[0-9]+$ ]] || ((10#$columns == 0)); then
		columns=${COLUMNS:-80}
	fi
	if [[ ! $columns =~ ^[0-9]+$ ]] || ((10#$columns == 0)); then columns=80; fi
	columns=$((10#$columns))
	width=$(ui_width "$text")
	printf '%s\n' "$(((width + columns - 1) / columns))"
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
