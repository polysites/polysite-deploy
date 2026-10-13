# Runs inside the NEW cms image before the migrations and reads files only. Refuses a migration that deletes data unless it carries
# the polysite:allow-destructive comment. Kept in step with GUARD_SCRIPT in deploy/deploy.sh (the Compose deploy runs the same checks).
set -eu
cd /repo/apps/cms
npm run --silent check:migrations
bad=0; marked=""
for f in src/migrations/*.ts /repo/plugins/*/migrations/*.js; do
  [ -f "$f" ] || continue
  if grep -q "polysite:allow-destructive" "$f"; then marked="$marked $f"; continue; fi
  case "$f" in
    *.js)
      if awk "/export async function up/{p=1} /export async function down/{p=0} p" "$f" | grep -Eqi "DROP[[:space:]]+(TABLE|COLUMN|TYPE|SCHEMA)|DELETE[[:space:]]+FROM|TRUNCATE"; then
        echo "DESTRUCTIVE: $f deletes data or structure in up()"; bad=1
      fi ;;
  esac
done
[ "$bad" = 0 ] || exit 3
if [ -n "$marked" ]; then
  echo "ALLOW-DESTRUCTIVE:$marked"
  [ "${POLYSITE_ALLOW_DESTRUCTIVE:-}" = "true" ] || { echo "These migrations are marked destructive. Set migrations.allowDestructive=true to run them (a rollback of images is then not safe: restore the backup)."; exit 3; }
fi
echo "Migration guard: ok"
