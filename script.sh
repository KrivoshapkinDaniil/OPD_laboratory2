#!/usr/bin/env bash
set -euo pipefail

TARGET_BRANCH="junior"
BATCH_LIMIT_MIB="${1:-900}"
REMOTE="${2:-origin}"
COMMIT_PREFIX="${3:-junior batch}"

MAX_FILE_BYTES=$((100 * 1024 * 1024))
BATCH_LIMIT_BYTES=$((BATCH_LIMIT_MIB * 1024 * 1024))

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Ошибка: не найдена команда '$1'. Запускайте скрипт из Git Bash." >&2
    exit 1
  }
}

for c in git awk sort wc tr grep mktemp date; do
  need_cmd "$c"
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Ошибка: запускать нужно внутри git-репозитория." >&2
  exit 1
fi

if ! [[ "$BATCH_LIMIT_MIB" =~ ^[0-9]+$ ]] || [ "$BATCH_LIMIT_MIB" -le 0 ]; then
  echo "Ошибка: первый аргумент должен быть целым числом MiB." >&2
  exit 1
fi

if git ls-files -u | grep -q .; then
  echo "Ошибка: в репозитории есть merge-conflicts." >&2
  exit 1
fi

if ! git diff --quiet --cached; then
  echo "Ошибка: у вас уже есть staged-изменения." >&2
  echo "Сначала выполните: git restore --staged ." >&2
  exit 1
fi

current_branch="$(git branch --show-current)"
if [ -z "$current_branch" ]; then
  echo "Ошибка: HEAD detached. Переключитесь на обычную ветку и запустите снова." >&2
  exit 1
fi

if [ -z "$(git status --porcelain=v1 --untracked-files=all)" ]; then
  echo "Нет изменений для коммита и push."
  exit 0
fi

tempdir="$(mktemp -d)"
trap 'rm -rf "$tempdir"' EXIT

list_file="$tempdir/files.tsv"
over_limit_file="$tempdir/over_limit.tsv"
: > "$list_file"
: > "$over_limit_file"

# Если сейчас не junior — временно stash, переключаемся/создаем junior, возвращаем изменения.
if [ "$current_branch" != "$TARGET_BRANCH" ]; then
  stash_name="__tmp_bigpush_$(date +%s)__"
  git stash push -u -m "$stash_name" >/dev/null

  if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    git switch "$TARGET_BRANCH" >/dev/null
  else
    git switch -c "$TARGET_BRANCH" >/dev/null
  fi

  if ! git stash pop --index >/dev/null; then
    echo "Ошибка: не удалось перенести изменения на ветку '$TARGET_BRANCH'." >&2
    echo "Проверьте конфликты вручную и повторите запуск." >&2
    exit 1
  fi
fi

collect_files() {
  git diff --name-only -z --diff-filter=ACMR
  git ls-files --others --exclude-standard -z
}

while IFS= read -r -d '' file; do
  [ -e "$file" ] || continue
  size="$(wc -c < "$file" | tr -d '[:space:]')"
  printf '%s\t%s\n' "$size" "$file" >> "$list_file"

  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then
    printf '%s\t%s\n' "$size" "$file" >> "$over_limit_file"
  fi
done < <(
  collect_files | awk 'BEGIN{RS="\0"} !seen[$0]++ { printf "%s\0", $0 }'
)

if [ ! -s "$list_file" ]; then
  echo "Нет подходящих файлов для обработки."
  exit 0
fi

if [ -s "$over_limit_file" ]; then
  echo "Ошибка: найдены файлы больше 100 MiB. GitHub их не примет:" >&2
  while IFS=$'\t' read -r size file; do
    mib=$((size / 1024 / 1024))
    echo "  ${mib} MiB  $file" >&2
  done < "$over_limit_file"
  exit 1
fi

sort -rn "$list_file" -o "$list_file"

batch_no=1
batch_bytes=0
batch_count=0

commit_and_push_batch() {
  local label
  label=$(printf '%03d' "$batch_no")

  git commit -m "$COMMIT_PREFIX $label" >/dev/null

  if git rev-parse --verify --quiet "$REMOTE/$TARGET_BRANCH" >/dev/null; then
    git push "$REMOTE" "$TARGET_BRANCH"
  else
    git push -u "$REMOTE" "$TARGET_BRANCH"
  fi

  batch_no=$((batch_no + 1))
  batch_bytes=0
  batch_count=0
}

while IFS=$'\t' read -r size file; do
  [ -n "$file" ] || continue

  if [ "$batch_count" -gt 0 ] && [ $((batch_bytes + size)) -gt "$BATCH_LIMIT_BYTES" ]; then
    commit_and_push_batch
  fi

  git add -- "$file"
  batch_bytes=$((batch_bytes + size))
  batch_count=$((batch_count + 1))
done < "$list_file"

if ! git diff --quiet --cached; then
  commit_and_push_batch
fi

echo "Готово. Файлы отправлены на ветку '$TARGET_BRANCH' пачками до ${BATCH_LIMIT_MIB} MiB."