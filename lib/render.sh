# 条件を先に取り除き、差し込みは元の文字列に一度だけ行う。
template_roles='orchestrator planner designer claude-implementer codex-implementer claude-fixer codex-fixer code-reviewer ux-reviewer security-reviewer performance-reviewer qa ci-monitor usage-monitor dependabot-merger'

template_filter() {
	local runtime_flags
	runtime_flags=$(jq -er '
		if type=="array" and length>0 and all(.[]; .=="claude" or .=="codex")
		then map("runtime-"+.) | join(" ") else error("使うランタイムが不正です") end
	' <<<"${runtimes:-[\"claude\",\"codex\"]}") || return 1
	awk -v enabled="$1 $runtime_flags" -v known="$template_roles runtime-claude runtime-codex" '
		function fail(message) {print FILENAME ":" FNR ": " message > "/dev/stderr"; bad=1; exit 1}
		BEGIN {
			n=split(known, keys, " "); for(i=1;i<=n;i++) valid[keys[i]]=1
			n=split(enabled, keys, " "); for(i=1;i<=n;i++) active[keys[i]]=1
			depth=0; keep[0]=1
		}
		/^<!-- IF .* -->$/ {
			line=$0; sub(/^<!-- IF /,"",line); sub(/ -->$/,"",line)
			n=split(line, keys, " "); yes=0
			for(i=1;i<=n;i++) {if(!(keys[i] in valid)) fail("未知の役"); if(keys[i] in active) yes=1}
			depth++; condition[depth]=yes; otherwise[depth]=0; keep[depth]=keep[depth-1] && yes; next
		}
		/^<!-- ELSE -->$/ {if(depth==0 || otherwise[depth]) fail("ELSE の不整合"); otherwise[depth]=1; keep[depth]=keep[depth-1] && !condition[depth]; next}
		/^<!-- ENDIF -->$/ {if(depth==0) fail("ENDIF の不整合"); depth--; next}
		/<!-- (IF|ELSE|ENDIF)/ {fail("印は独立した行にする")}
		keep[depth] {print}
		END {if(!bad && depth!=0) {print "閉じていない印" > "/dev/stderr"; exit 1}}
	' "$2"
}

# values は JSON オブジェクト。改行や引用符も値として扱い、挿入後に再解釈しない。
template_apply() {
	jq -njr --slurpfile values "$1" --rawfile text "$2" '
		"\\{\\{(?<key>[A-Za-z0-9_.-]+)\\}\\}" as $pattern |
		if ($text | gsub($pattern; "") | test("\\{\\{|\\}\\}")) then error("未知の差し込み") else
		$text | gsub($pattern; .key as $key |
			if ($values[0][$key] | type=="string" and length>0) then $values[0][$key]
			else error("値が足りない: " + $key) end)
		end'
}

# 同梱ひな形の front matter は一行のスカラーだけを使う。
template_field() {
	awk -v key="$2" '
		NR==1 {if($0!="---") exit 1; inside=1; next}
		inside && $0=="---" {closed=1; exit}
		inside && index($0,key ": ")==1 {
			if(seen++) exit 1
			sub(/^[^:]+: */, ""); if($0~/^".*"$/) {sub(/^"/, ""); sub(/"$/, "")}; value=$0
		}
		END {if(!closed || seen>1) exit 1; if(seen) print value}
	' "$1"
}

template_body() {
	awk 'NR==1 {next} !body && $0=="---" {body=1; next} body {print}' "$1"
}
