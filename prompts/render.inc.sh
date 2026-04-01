# Sourced by generate-*-message.sh and generate-release-note.sh (expects SCRIPT_DIR).
# Requires python3 for {{KEY}} substitution via prompts/render.py.
render_prompt_template() {
    local rel="$1"
    shift
    local template_file="$SCRIPT_DIR/prompts/$rel"
    if [ ! -f "$template_file" ]; then
        echo "Error: prompt template not found: $template_file" >&2
        exit 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 "$SCRIPT_DIR/prompts/render.py" "$template_file" "$@"
    elif command -v python >/dev/null 2>&1; then
        python "$SCRIPT_DIR/prompts/render.py" "$template_file" "$@"
    else
        echo "Error: python3 is required to render prompt templates (install Python 3)." >&2
        exit 1
    fi
}
