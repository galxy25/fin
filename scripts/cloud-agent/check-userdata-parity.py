#!/usr/bin/env python3
"""Verifies the documented byte-parity contract between the two copies of the
worker bootstrap: launch.sh's USER_DATA heredoc (plus its optional browser
block) and control-plane/lambda.py's USER_DATA / BROWSER_USER_DATA templates.

The contract ("byte-for-byte; the two presigned URLs are the only
substitutions") has always lived in comments; this makes it checkable:

    python3 scripts/cloud-agent/check-userdata-parity.py

Exit 0 with "parity ok" when the rendered blocks match, exit 1 with a unified
diff when they don't. lambda.py is read via ast (never imported), so this runs
anywhere — no boto3, no AWS anything.
"""
import ast
import difflib
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent


def lambda_templates():
    tree = ast.parse((HERE / "control-plane" / "lambda.py").read_text())
    found = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in ("USER_DATA", "BROWSER_USER_DATA"):
                    found[target.id] = ast.literal_eval(node.value)
    missing = {"USER_DATA", "BROWSER_USER_DATA"} - set(found)
    if missing:
        sys.exit("lambda.py is missing template(s): {}".format(", ".join(sorted(missing))))
    return found["USER_DATA"], found["BROWSER_USER_DATA"]


def launch_blocks():
    text = (HERE / "launch.sh").read_text()
    main = re.search(r"USER_DATA=\$\(cat <<EOF\n(.*?)\nEOF\n\)", text, re.S)
    browser = re.search(r"\$\(cat <<'BROWSER'\n(.*?)\nBROWSER\n\)", text, re.S)
    if not main or not browser:
        sys.exit("could not find the USER_DATA heredoc or the BROWSER block in launch.sh")
    return main.group(1), browser.group(1)


def normalize(text):
    # The presigned URLs are the contract's only permitted substitutions.
    for token in ("{binary_url}", "{config_url}", "$BINARY_URL", "$CONFIG_URL"):
        text = text.replace("'" + token + "'", "'URL'")
    # Shell heredoc extraction and Python string literals disagree about
    # leading/trailing blank lines; the contract is about the lines between.
    return text.strip("\n") + "\n"


def compare(label, lambda_text, launch_text):
    lambda_text, launch_text = normalize(lambda_text), normalize(launch_text)
    if lambda_text == launch_text:
        return True
    sys.stdout.writelines(difflib.unified_diff(
        lambda_text.splitlines(keepends=True),
        launch_text.splitlines(keepends=True),
        fromfile="lambda.py " + label,
        tofile="launch.sh " + label,
    ))
    return False


def main():
    lambda_main, lambda_browser = lambda_templates()
    launch_main, launch_browser = launch_blocks()
    ok = compare("USER_DATA", lambda_main, launch_main)
    ok = compare("BROWSER_USER_DATA", lambda_browser, launch_browser) and ok
    if not ok:
        sys.exit(1)
    print("parity ok: USER_DATA and BROWSER_USER_DATA match between lambda.py and launch.sh")


if __name__ == "__main__":
    main()
