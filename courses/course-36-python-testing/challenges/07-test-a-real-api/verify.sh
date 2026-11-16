#!/usr/bin/env bash
# Verifier for "Test a Real API End-to-End".
# Network is blocked (enrich must be mocked). Your suite must pass on the
# correct app and fail on every mutant.
set -uo pipefail

SLUG="07-test-a-real-api"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{isolate_every_test}'

fail() { echo "✗ $1"; exit 1; }

[ -f "$WORK/test_api.py" ] || fail "test_api.py not found — run setup.sh and write your tests first"

grep -q "TestClient" "$WORK/test_api.py" || \
    fail "this challenge requires fastapi.testclient.TestClient"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
    PYBIN="$WORK/.venv/bin/python"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
    PYBIN="python3"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest fastapi httpx requests"
fi

for mod in fastapi httpx requests; do
    "$PYBIN" -c "import $mod" 2>/dev/null || \
        fail "'$mod' is not installed — cd $WORK && . .venv/bin/activate && pip install fastapi httpx requests"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$WORK/test_api.py" "$TMP/test_api.py"

# Block the real `requests` library (NOT sockets — TestClient needs sockets
# internally for its asyncio event loop). Any un-mocked api.requests.get call
# falls through to the real Session.request and fails loudly.
cat > "$TMP/conftest.py" << 'PYEOF'
import pytest
import requests


@pytest.fixture(autouse=True)
def _no_real_network(monkeypatch):
    def _guard(*args, **kwargs):
        raise RuntimeError("real network access in a test — mock api.requests!")
    monkeypatch.setattr(requests.sessions.Session, "request", _guard)
PYEOF

emit() {
    case "$1" in
    correct)       sc=201; title_check=1; get_404=1; do_del=1; field=count ;;
    create_200)    sc=200; title_check=1; get_404=1; do_del=1; field=count ;;
    no_title)      sc=201; title_check=0; get_404=1; do_del=1; field=count ;;
    get_no_404)    sc=201; title_check=1; get_404=0; do_del=1; field=count ;;
    delete_noop)   sc=201; title_check=1; get_404=1; do_del=0; field=count ;;
    enrich_field)  sc=201; title_check=1; get_404=1; do_del=1; field=words ;;
    esac

    {
        echo "import requests"
        echo "from fastapi import FastAPI, HTTPException"
        echo "from pydantic import BaseModel"
        echo "app = FastAPI()"
        echo "_db = {}"
        echo '_next_id = {"v": 1}'
        echo "class NoteIn(BaseModel):"
        echo "    title: str"
        echo '    body: str = ""'
        echo "@app.post('/notes', status_code=$sc)"
        echo "def create_note(note: NoteIn):"
        if [ "$title_check" = "1" ]; then
            echo "    if not note.title.strip():"
            echo "        raise HTTPException(status_code=422, detail='title required')"
        else
            echo "    pass"
        fi
        echo "    nid = _next_id['v']"
        echo "    _next_id['v'] += 1"
        echo "    _db[nid] = {'id': nid, 'title': note.title, 'body': note.body}"
        echo "    return _db[nid]"
        echo "@app.get('/notes/{nid}')"
        echo "def get_note(nid: int):"
        if [ "$get_404" = "1" ]; then
            echo "    if nid not in _db:"
            echo "        raise HTTPException(status_code=404, detail='not found')"
            echo "    return _db[nid]"
        else
            echo "    return _db.get(nid)"
        fi
        echo "@app.get('/notes')"
        echo "def list_notes():"
        echo "    return list(_db.values())"
        echo "@app.delete('/notes/{nid}', status_code=204)"
        echo "def delete_note(nid: int):"
        echo "    if nid not in _db:"
        echo "        raise HTTPException(status_code=404, detail='not found')"
        if [ "$do_del" = "1" ]; then
            echo "    del _db[nid]"
        else
            echo "    pass"
        fi
        echo "@app.get('/notes/{nid}/enrich')"
        echo "def enrich(nid: int):"
        echo "    if nid not in _db:"
        echo "        raise HTTPException(status_code=404, detail='not found')"
        echo "    resp = requests.get(f\"https://api.example.com/wordcount?text={_db[nid]['body']}\")"
        echo "    resp.raise_for_status()"
        echo "    return {'id': nid, 'word_count': resp.json()['$field']}"
    } > "$TMP/api.py"
}

run() {
    rm -rf "$TMP/__pycache__"
    ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider test_api.py >"$TMP/_out.txt" 2>&1 )
    return $?
}

emit correct
if ! run; then
    echo "✗ Your tests FAIL against the correct API (with the network blocked)."
    echo "  If you see 'real network access', mock api.requests in your enrich test."
    echo "─────────────────────────────────────────────"
    sed -n '1,50p' "$TMP/_out.txt"
    exit 1
fi

MUTANTS="create_200:POST /notes returning 200 instead of 201
no_title:a blank/whitespace title being accepted instead of 422
get_no_404:GET of a missing note returning 200/null instead of 404
delete_noop:DELETE returning 204 but not actually removing the note
enrich_field:enrich reading the wrong field from the external API response"

survived=0
while IFS=: read -r name desc; do
    [ -z "$name" ] && continue
    emit "$name"
    if run; then
        echo "✗ Your suite still PASSES with this bug: $desc"
        survived=1
    fi
done <<< "$MUTANTS"

[ "$survived" -eq 0 ] || fail "some endpoints/paths are under-tested — strengthen your assertions and retry"

echo
echo "All checks passed — full CRUD, error paths, isolation, and a mocked boundary. Submit this flag:"
echo
echo "    $FLAG"
