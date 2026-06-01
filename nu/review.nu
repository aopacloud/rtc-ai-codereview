#!/usr/bin/env nu
# Author: hustcer
# Created: 2025/01/29 13:02:15
# TODO:
#  [√] DeepSeek code review for GitHub PRs
#  [√] DeepSeek code review for local commit changes
#  [√] Debug mode
#  [√] Output token usage info
#  [√] Perform CR for changes that either include or exclude specific files
#  [√] Support streaming output for local code review
#  [√] Support using custom patch command to get diff content
#  [ ] Add more action outputs
# Description: A script to do code review by DeepSeek
# REF:
#   - https://docs.github.com/en/rest/issues/comments
#   - https://docs.github.com/en/rest/pulls/pulls
# Env vars:
#  GITHUB_TOKEN: Your GitHub API token
#  CHAT_TOKEN: Your DeepSeek API token
#  BASE_URL: DeepSeek API base URL
#  SYSTEM_PROMPT: System prompt message
#  USER_PROMPT: User prompt message
# Usage:
#  - Local Repo Review: just cr
#  - Local Repo Review: just cr -f HEAD~1 --debug
#  - Local PR Review: just cr -r hustcer/deepseek-review -n 32

use std-rfc/kv *
use diff.nu [get-diff]
use common.nu [
  ECODE, NO_TOKEN_TIP, hr-line, is-installed, windows?, mac?,
  compare-ver, compact-record, git-check, has-ref, GITHUB_API_BASE
]

const IGNORED_MESSAGES = {
  '-alive': true,                   # The server is alive
  'data: [DONE]': true,             # The end of the response
  ': OPENROUTER PROCESSING': true,  # OPENROUTER in PROCESSING message
}

# It takes longer to respond to requests made with unknown/rare user agents.
# When make http post pretend to be curl, it gets a response just as quickly as curl.
const HTTP_HEADERS = [User-Agent curl/8.9]

const DEFAULT_OPTIONS = {
  MODEL: 'deepseek-v4-flash',
  TEMPERATURE: 0.3,
  BASE_URL: 'https://api.deepseek.com',
  USER_PROMPT: 'Please review the following code changes:',
  SYS_PROMPT: 'You are a professional code review assistant responsible for analyzing code changes in GitHub Pull Requests. Identify potential issues such as code style violations, logical errors, security vulnerabilities, and provide improvement suggestions. Clearly list the problems and recommendations in a concise manner.',
}

# Use DeepSeek AI to review code changes locally or in GitHub Actions
export def --env deepseek-review [
  token?: string,           # Your DeepSeek API token, fallback to CHAT_TOKEN env var
  --debug(-d),              # Debug mode
  --repo(-r): string,       # GitHub repo name, e.g. hustcer/deepseek-review, or local repo path / alias
  --output(-o): string,     # Output file path
  --pr-number(-n): string,  # GitHub PR number
  --gh-token(-k): string,   # Your GitHub token, fallback to GITHUB_TOKEN env var
  --diff-to(-t): string,    # Git diff ending commit SHA
  --diff-from(-f): string,  # Git diff starting commit SHA
  --patch-cmd(-c): string,  # The `git show` or `git diff` command to get the diff content, for local CR only
  --max-length(-l): int,    # Maximum length of the content for review, 0 means no limit.
  --model(-m): string,      # Model name, or read from CHAT_MODEL env var, `deepseek-v4-flash` by default
  --base-url(-b): string,   # DeepSeek API base URL, fallback to BASE_URL env var
  --chat-url(-U): string,   # DeepSeek Model chat full API URL, e.g. http://localhost:11535/api/chat
  --sys-prompt(-s): string  # Default to $DEFAULT_OPTIONS.SYS_PROMPT,
  --user-prompt(-u): string # Default to $DEFAULT_OPTIONS.USER_PROMPT,
  --include(-i): string,    # Comma separated file patterns to include in the code review
  --exclude(-x): string,    # Comma separated file patterns to exclude in the code review
  --temperature(-T): float, # Temperature for the model, between `0` and `2`, default value `0.3`
]: nothing -> nothing {

  $env.config.table.mode = 'psql'
  let local_repo = $env.PWD
  let write_file = ($output | is-not-empty)
  let is_action = ($env.GITHUB_ACTIONS? == 'true')
  let token = $token | default $env.CHAT_TOKEN?
  let repo = $repo | default $env.DEFAULT_GITHUB_REPO?
  let CHAT_HEADER = [Authorization $'Bearer ($token)']
  let stream = if $is_action or $write_file { false } else { true }
  let model = $model | default $env.CHAT_MODEL? | default $DEFAULT_OPTIONS.MODEL
  let base_url = $base_url | default $env.BASE_URL? | default $DEFAULT_OPTIONS.BASE_URL
  let url = $chat_url | default $env.CHAT_URL? | default $'($base_url)/chat/completions'
  let max_length = try { $max_length | default ($env.MAX_LENGTH? | default 0 | into int) } catch { 0 }
  let temperature = try { $temperature | default $env.TEMPERATURE? | default $DEFAULT_OPTIONS.TEMPERATURE | into float } catch { $DEFAULT_OPTIONS.TEMPERATURE }
  # Determine output mode
  let output_mode = if $is_action { 'action' } else if ($output | is-not-empty) { 'file' } else { 'console' }

  validate-temperature $temperature
  let setting = {
    repo: $repo,
    model: $model,
    chat_url: $url,
    include: $include,
    exclude: $exclude,
    diff_to: $diff_to,
    diff_from: $diff_from,
    patch_cmd: $patch_cmd,
    pr_number: $pr_number,
    max_length: $max_length,
    local_repo: $local_repo,
    temperature: $temperature,
  }
  $env.GH_TOKEN = $gh_token | default $env.GITHUB_TOKEN?

  validate-token $token --pr-number $pr_number --repo $repo
  let hint = if not $is_action and ($pr_number | is-empty) {
    $'🚀 Initiate the code review by DeepSeek AI for local changes ...'
  } else {
    $'🚀 Initiate the code review by DeepSeek AI for PR (ansi g)#($pr_number)(ansi reset) in (ansi g)($repo)(ansi reset) ...'
  }
  print $hint; print -n (char nl)
  if ($pr_number | is-empty) {
    print 'Current Settings:'; hr-line
    $setting | compact-record | reject -o repo | print; print -n (char nl)
  }
  # Print diff range info early so user can see it before review starts
  let diff_range = build-diff-range $setting
  if ($diff_range | is-not-empty) {
    print $diff_range
  }

  let content = (
    get-diff --pr-number $pr_number --repo $repo --diff-to $diff_to
             --diff-from $diff_from --include $include --exclude $exclude --patch-cmd $patch_cmd)
  let length = $content | str stats | get unicode-width
  if ($max_length != 0) and ($length > $max_length) {
    print $'(char nl)(ansi r)The content length ($length) exceeds the maximum limit ($max_length), review skipped.(ansi reset)'
    exit $ECODE.SUCCESS
  }
  print $'Review content length: (ansi g)($length)(ansi reset), current max length: (ansi g)($max_length)(ansi reset)'
  let sys_prompt = $sys_prompt | default $env.SYSTEM_PROMPT? | default $DEFAULT_OPTIONS.SYS_PROMPT
  let user_prompt = $user_prompt | default $env.USER_PROMPT? | default $DEFAULT_OPTIONS.USER_PROMPT
  let payload = {
    model: $model,
    stream: $stream,
    temperature: $temperature,
    messages: [
      { role: 'system', content: $sys_prompt },
      { role: 'user', content: $"($user_prompt):\n($content)" }
    ],
    thinking: { type: 'disabled' }
  }
  if $debug { print $'(char nl)Code Changes:'; hr-line; print $content }
  print $'(char nl)Waiting for response from (ansi g)($url)(ansi reset) ...'
  if $stream { streaming-output $url $payload --headers $CHAT_HEADER --debug=$debug; return }

  let response = http post -e -H $CHAT_HEADER -t application/json $url $payload
  if ($response | is-empty) {
    print $'(ansi r)Oops, No response returned from ($url) ...(ansi reset)'
    exit $ECODE.SERVER_ERROR
  }
  if $debug { print $'DeepSeek Model Response:'; hr-line; $response | table -e | print }
  if ($response | describe) == 'string' {
    print $'✖️ Code review failed！Error: '; hr-line; print $response
    exit $ECODE.SERVER_ERROR
  }
  let message = $response | get -o choices.0.message
  let reason = $message | coalesce-reasoning
  let review = $message.content? | default ($response | get -o message.content)
  # Strip inline thinking blocks (e.g. MiniMax puts <think>...</think> in content)
  let review = $review | str replace --all --regex '(?s)<think>.*?</think>\s*' ''
  let review = $review | str trim
  if ($review | is-empty) {
    print $'✖️ Code review failed！No review result returned from ($base_url) ...'
    exit $ECODE.SERVER_ERROR
  }
  # Only include reasoning in action output (as collapsible details)
  let result = if ($reason | is-empty) {
    $review
  } else if $is_action {
    ['<details>' '<summary> Reasoning Details</summary>' $reason "</details>\n" $review] | str join "\n"
  } else {
    $review
  }

  match $output_mode {
    'action' => {
      post-comments-to-pr $repo $pr_number $result
      print $'✅ Code review finished！PR (ansi g)#($pr_number)(ansi reset) review result was posted as a comment.'
    }
    'file' => { write-review-to-file $output $setting $result $response }
    _ => { print $'Code Review Result:'; hr-line; print $result }
  }


  if ($response.usage? | is-not-empty) {
    print $'(char nl)Token Usage:'; hr-line
    $response.usage? | table -e | print
  }
}

# Strip the "二、发现问题" section header and all its content from the review markdown
# The individual findings are posted as separate review comments, so they should not
# appear in the Issue Comment (full markdown) to avoid duplication
def strip-problem-section [review: string] {
  let lines = $review | lines
  # Find the line containing "二、发现问题"
  let section_idx = try { $lines | enumerate | where { $in.item | str contains '二、发现问题' } | get 0 | get index } catch { -1 }
  if $section_idx < 0 { return $review }
  # Keep only lines before "二、发现问题" and trim trailing empty lines
  let kept = $lines | take $section_idx | reverse | skip while { $in | str trim | is-empty } | reverse
  $kept | str join "\n"
}

# Write the code review result to a file
# Also saves suggestion payloads as JSON for local debugging
def write-review-to-file [
  file: string,           # Output file path
  setting: record,        # Review settings
  result: string,         # Review result
  response: record,       # DeepSeek API response
] {
  let file = (if not ($file | str ends-with '.md') { $'($file).md' } else { $file })
  let token_usage = if ($response.usage? | is-empty) { [] } else {
    ['## Token Usage', '', ($response.usage? | transpose key val | to md --pretty)]
  }
  # Generate content sections
  let content_sections = [
    '# DeepSeek Code Review Result', ''
    $"Generated at: (date now | format date '%Y/%m/%d %H:%M:%S')", ''
    '## Code Review Settings', ''
    ($setting | compact-record | reject -o repo | transpose key val | to md --pretty)
    '', '## Review Detail', '', $result, '', ...$token_usage
  ]
  try {
    $content_sections | str join (char nl) | save --force $file
    print $'Code Review Result saved to (ansi g)($file)(ansi reset)'
  } catch {|err|
    print $'(ansi r)Failed to save review result: (ansi reset)'
    $err | table -e | print
  }

  # Parse findings and save suggestion payloads as JSON for debugging
  let findings = parse-findings $result
  if ($findings | is-not-empty) {
    let payloads = $findings | each {|f|
      let sug = $f.body | str replace --regex '(?s).*```suggestion\s*' '' | str replace --regex '```.*' '' | str trim
      {
        path: $f.path
        start_line: $f.start_line
        line: $f.line
        side: 'RIGHT'
        body: $f.body
        _debug: {
          ai_line_range: $'($f.start_line)-($f.line)'
          extracted_suggestion: $sug
          suggestion_lines: ($sug | lines | length)
        }
      }
    }
    let json_file = $file | str replace '.md' '.suggestions.json'
    try {
      $payloads | to json -i 2 | save --force $json_file
      print $'Suggestion payloads saved to (ansi g)($json_file)(ansi reset)'
      # Print each payload for quick comparison
      for p in $payloads {
        print $'  📤 ($p.path):($p.start_line)-($p.line)'
        print $'     suggestion:'
        print $p._debug.extracted_suggestion
        print ''
      }
    } catch {|err|
      print $'(ansi r)Failed to save suggestion payloads: (ansi reset)'
      $err | table -e | print
    }
  }
}

# Validate the DeepSeek API token
def validate-token [token?: string, --pr-number: string, --repo: string] {
  if ($token | is-empty) {
    print $'(ansi r)Please provide your DeepSeek API token by setting `CHAT_TOKEN` or passing it as an argument.(ansi reset)'
    if ($pr_number | is-not-empty) { post-comments-to-pr $repo $pr_number $NO_TOKEN_TIP }
    exit $ECODE.INVALID_PARAMETER
  }
  $token
}

# Validate the temperature value
def validate-temperature [temp: float] {
  if ($temp < 0) or ($temp > 2) {
    print $'(ansi r)Invalid temperature value, should be in the range of 0 to 2.(ansi reset)'
    exit $ECODE.INVALID_PARAMETER
  }
  $temp
}

# Post review comments to GitHub PR
# Posts the full review as an issue comment,
# and additionally posts inline PR review comments for each suggestion block
# to enable the "Commit suggestion" button.
def post-comments-to-pr [
  repo: string,        # GitHub repository name, e.g. hustcer/deepseek-review
  pr_number: string,   # GitHub PR number
  comments: string,    # Comments content to post
] {
  let BASE_HEADER = [Authorization $'Bearer ($env.GH_TOKEN)' Accept application/vnd.github.v3+json ...$HTTP_HEADERS]

  # 1. Post the full review as an issue comment (strip "二、发现问题" section)
  let comment_body = strip-problem-section $comments
  let comment_url = $'($GITHUB_API_BASE)/repos/($repo)/issues/($pr_number)/comments'
  try {
    http post -t application/json -H $BASE_HEADER $comment_url { body: $comment_body }
  } catch {|err|
    print $'(ansi r)Failed to post comments to PR: (ansi reset)'
    $err | table -e | print
    exit $ECODE.SERVER_ERROR
  }

  # 2. Parse findings and post inline review comments with suggestion blocks
  # Requires commit_id for GitHub to position the comment on the correct diff line
  let pr_data = try {
    http get -H $BASE_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)'
  } catch {|err|
    print $'  ⚠️ Failed to fetch PR data for commit_id: (try { $err.msg? | default $'($err)' } catch { $'($err)' })'
    null
  }
  let commit_id = try { $pr_data | get -o head | get -o sha | default '' } catch { '' }
  if ($commit_id | is-not-empty) {
    print $'  📌 commit_id: ($commit_id)'
  } else {
    print $'  ⚠️ No commit_id available, review comments may fail to position'
  }

  let review_comment_url = $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)/comments'
  let findings = parse-findings $comments
  print $'  📋 Parsed ($findings | length) findings with suggestion blocks'
  # Debug: print each finding details
  for f in $findings {
    print $'  🔍 Finding: ($f.path):($f.line)'
    print $'     body preview: ($f.body | str substring 0..<150)...'
  }

  # Fetch the PR diff to validate line numbers
  let diff_hunks = try {
    let diff_data = http get -H $BASE_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)'
    let diff_url = $diff_data.diff_url? | default ''
    # Use the commits API to get per-file diff info
    let files = http get -H $BASE_HEADER $'($GITHUB_API_BASE)/repos/($repo)/pulls/($pr_number)/files'
    $files | each {|f|
      let patch = $f.patch? | default ''
      { path: $f.filename, additions: $f.additions, changes: $f.changes, patch: $patch }
    } | where { $in.changes > 0 }
  } catch { [] }
  print $'  📋 Fetched diff info for ($diff_hunks | length) files'

  for finding in $findings {
    # For findings WITH suggestion, find correct line range by matching content in diff
    # For findings WITHOUT suggestion, use AI-reported line numbers directly
    let line_range = if $finding.has_suggestion {
      find-line-by-content $finding $diff_hunks
    } else {
      { start_line: $finding.start_line, end_line: $finding.line }
    }
    let start_line = $line_range.start_line
    let end_line = $line_range.end_line

    # Build payload with start_line for multi-line comments
    let payload = if $start_line != $end_line {
      {
        path: $finding.path
        start_line: $start_line
        line: $end_line
        side: 'RIGHT'
        body: $finding.body
      }
    } else {
      {
        path: $finding.path
        line: $end_line
        side: 'RIGHT'
        body: $finding.body
      }
    }
    # Include commit_id if available for accurate diff positioning
    let payload = if ($commit_id | is-not-empty) {
      $payload | merge { commit_id: $commit_id }
    } else {
      $payload
    }
    try {
      # Debug: print the payload being submitted
      let sug_tag = if $finding.has_suggestion { 'suggestion' } else { 'comment-only' }
      print $'  📤 Review comment payload [($sug_tag)]:'
      print $'     path: ($payload.path)'
      print $'     line: ($payload.line)'
      if ($payload | get -o start_line | is-not-empty) {
        print $'     start_line: ($payload.start_line)'
      }
      print $'     side: ($payload.side)'
      print $'     commit_id: ($commit_id)'
      print $'     body:'
      print $payload.body
      http post -t application/json -H $BASE_HEADER $review_comment_url $payload
      print $'  ✅ Posted review comment on ($finding.path):($start_line)-($end_line) [($sug_tag)]'
    } catch {|err|
      let err_msg = try { $err.msg? | default '' } catch { '' }
      let err_detail = if ($err_msg | is-not-empty) { $err_msg } else { try { $err | str substring 0..<200 } catch { $'($err)' } }
      print $'  ⚠️ Skipped review comment on ($finding.path):($start_line)-($end_line) - ($err_detail)'
    }
  }
}

# Parse the AI review response to extract findings with suggestion blocks
# Each finding includes: path, start_line, line, and body (with suggestion block)
# Line range is extracted from **建议修改** diff for accuracy
export def parse-findings [review: string] {
  # Split by section separator ---
  let sections = $review | split row '---' | where { $in | str trim | is-not-empty }

  $sections | each {|section|
    let trimmed = $section | str trim

    # Extract file path from ### [severity] `path:line`
    let heading_lines = $trimmed | lines | where { ($in | str starts-with '###') and ($in | str contains '`') }
    if ($heading_lines | is-empty) { return }
    let heading_line = $heading_lines | first
    # Extract content between backticks
    let file_ref = $heading_line | str replace --regex '.*?`([^`]+)`.*' '$1'
    let parts = $file_ref | split row ':'
    if ($parts | length) < 2 { return }
    let path = $parts | get 0 | str trim

    # Get the line range from the heading
    let line_parts = $parts | get 1 | split row '-'
    let start_line = try { $line_parts | get 0 | str trim | into int } catch { return }
    let end_line = try { $line_parts | get 1 | str trim | into int } catch { $start_line }

    # Check for suggestion block
    let has_suggestion = ($trimmed | str contains '```suggestion')

    if $has_suggestion {
      # Calculate end_line from suggestion content line count
      let suggestion_lines = extract-suggestion-lines $trimmed
      let sug_line_count = $suggestion_lines | length
      let end_line = $start_line + $sug_line_count - 1
      # Build the review comment body (priority + description + suggestion)
      let body = build-review-comment-body $trimmed
      { path: $path, start_line: $start_line, line: $end_line, body: $body, has_suggestion: true }
    } else {
      # No suggestion block — still report as review comment with description only
      let body = build-review-comment-body-no-suggestion $trimmed
      { path: $path, start_line: $start_line, line: $end_line, body: $body, has_suggestion: false }
    }
  } | where { $in | is-not-empty }
}

# Extract the raw lines from the ```suggestion block
# Returns a list of code lines (without the suggestion markers)
export def extract-suggestion-lines [section: string] {
  let lines = $section | lines
  let sug_start = try { $lines | enumerate | where { $in.item | str starts-with '```suggestion' } | get 0 | get index } catch { -1 }
  if $sug_start < 0 { return [] }
  # Find the closing ```
  let after_start = $lines | skip ($sug_start + 1) | enumerate
  let sug_end = try { $after_start | where { $in.item | str starts-with '```' } | get 0 | get index } catch { -1 }
  if $sug_end < 0 { return [] }
  # Extract lines between ```suggestion and ```
  $lines | skip ($sug_start + 1) | take $sug_end
}

# Extract the precise line range from the **建议修改** diff section
# Returns the start and end line numbers of the + lines in the diff
# NOTE: This function is kept for reference but no longer used in parse-findings
export def extract-suggest-line-range [section: string] {
  let lines = $section | lines
  # Find the **建议修改：** marker
  let suggest_idx = try { $lines | enumerate | where { $in.item | str contains '**建议修改：**' } | get 0 | get index } catch { -1 }
  if $suggest_idx < 0 { return { start: 0, end: 0 } }

  # Find the diff code block after **建议修改：**
  # Look for lines like + 32:    code or + 33:    code to get the replacement line range
  let after_marker = $lines | skip ($suggest_idx + 1)
  let plus_lines = $after_marker | where { $in | str starts-with '+' } | where { $in | str contains ':' }

  if ($plus_lines | is-empty) { return { start: 0, end: 0 } }

  # Extract line numbers from + N:    code format
  let line_nums = $plus_lines | each {|line|
    let match = $line | str replace --regex '^\+\s*(\d+):.*' '$1'
    try { $match | into int } catch { 0 }
  } | where { $in > 0 }

  if ($line_nums | is-empty) { return { start: 0, end: 0 } }

  let start = $line_nums | math min
  let end = $line_nums | math max
  { start: $start, end: $end }
}

# Find the correct line range for a finding by searching suggestion content in the PR diff
# This is more reliable than trusting the AI-reported line numbers
# Returns { start_line, end_line } with corrected values, or the original if no match found
def find-line-by-content [finding: record, diff_hunks: list] {
  let path = $finding.path
  let ai_start = $finding.start_line
  let ai_end = $finding.line

  # Extract suggestion code lines
  let sug_lines = extract-suggestion-lines $finding.body
  if ($sug_lines | is-empty) {
    print $'    ℹ️ No suggestion content in ($path), using AI lines ($ai_start)-($ai_end)'
    return { start_line: $ai_start, end_line: $ai_end }
  }

  # Find the matching file in diff
  let file_info = $diff_hunks | where { $in.path == $path } | get -o 0
  if ($file_info | is-empty) {
    print $'    ℹ️ ($path) not found in diff, using AI lines ($ai_start)-($ai_end)'
    return { start_line: $ai_start, end_line: $ai_end }
  }
  let patch = $file_info.patch
  if ($patch | is-empty) {
    print $'    ℹ️ No patch for ($path), using AI lines ($ai_start)-($ai_end)'
    return { start_line: $ai_start, end_line: $ai_end }
  }

  # Parse the diff to build line-number → content mapping for RIGHT side
  let line_map = parse-diff-line-map $patch
  if ($line_map | is-empty) {
    print $'    ℹ️ Could not parse patch for ($path), using AI lines ($ai_start)-($ai_end)'
    return { start_line: $ai_start, end_line: $ai_end }
  }

  # Use the first line of suggestion to find the start position
  # Normalize both sides: strip leading whitespace for fuzzy matching
  let first_sug = $sug_lines | get 0 | str trim
  let sug_line_count = $sug_lines | length

  # Search for the first suggestion line in the diff content
  let matches = $line_map | where { $in.content | str trim | str contains $first_sug }

  if ($matches | is-empty) {
    # Try a more lenient search: use a shorter substring
    let short_key = if ($first_sug | str length) > 30 {
      $first_sug | str substring 0..<30
    } else { $first_sug }
    let lenient_matches = $line_map | where { $in.content | str trim | str contains $short_key }
    if ($lenient_matches | is-empty) {
      print $'    ⚠️ ($path): suggestion content not found in diff, using AI lines ($ai_start)-($ai_end)'
      return { start_line: $ai_start, end_line: $ai_end }
    }
    # Use the match closest to AI-reported line
    let best = $lenient_matches | sort-by line | where { $in.line >= $ai_start } | get -o 0
    let best = if ($best | is-not-empty) { $best } else { $lenient_matches | last }
    let found_start = $best.line
    let found_end = $found_start + $sug_line_count - 1
    # Validate end line is in diff
    let valid_lines = $line_map | get line
    let found_end = if ($valid_lines | where { $in >= $found_end } | is-not-empty) { $found_end } else { $ai_end }
    if $found_start != $ai_start {
      print $'    🔄 ($path): AI line ($ai_start)-($ai_end) → diff matched ($found_start)-($found_end)'
    }
    return { start_line: $found_start, end_line: $found_end }
  }

  # Prefer the match closest to the AI-reported line
  let best = $matches | sort-by line | where { $in.line >= $ai_start } | get -o 0
  let best = if ($best | is-not-empty) { $best } else { $matches | sort-by line | last }
  let found_start = $best.line
  let found_end = $found_start + $sug_line_count - 1

  # Validate: end line should exist in the diff
  let valid_lines = $line_map | get line
  let found_end = if ($valid_lines | where { $in >= $found_end } | is-not-empty) { $found_end } else { $ai_end }

  if $found_start != $ai_start or $found_end != $ai_end {
    print $'    🔄 ($path): AI line ($ai_start)-($ai_end) → diff matched ($found_start)-($found_end)'
  }
  { start_line: $found_start, end_line: $found_end }
}

# Parse a unified diff patch and return a list of {line, content} for RIGHT-side lines
# This builds a complete mapping from line number to code content
def parse-diff-line-map [patch: string] {
  let lines = $patch | lines
  mut right_line = 0
  mut result = []

  for line in $lines {
    if ($line | str starts-with '@@') {
      let start = $line | str replace --regex '.*\+(\d+).*' '$1' | into int
      if ($start | describe) == 'int' { $right_line = $start }
    } else if $right_line > 0 {
      if ($line | str starts-with '+') {
        # Added line — strip the '+' prefix
        let line_len = $line | str length
        let content = $line | str substring 1..<$line_len
        $result = $result | append { line: $right_line, content: $content }
        $right_line += 1
      } else if ($line | str starts-with '-') {
        # Deleted line — not in RIGHT side
      } else {
        # Context line
        let line_len = $line | str length
        let content = if $line_len > 0 { $line | str substring 1..<$line_len } else { '' }
        $result = $result | append { line: $right_line, content: $content }
        $right_line += 1
      }
    }
  }
  $result
}

# Parse a unified diff patch and return all valid RIGHT-side line numbers
# These are lines that exist in the new version and appear in the diff
 def parse-diff-valid-lines [patch: string] {
  let lines = $patch | lines
  mut right_line = 0
  mut valid = []

  for line in $lines {
    # Parse hunk header: @@ -old_start,count +new_start,count @@
    if ($line | str starts-with '@@') {
      let start = $line | str replace --regex '.*\+(\d+).*' '$1' | into int
      if ($start | describe) == 'int' { $right_line = $start }
    } else if $right_line > 0 {
      if ($line | str starts-with '+') {
        # Added line — valid RIGHT line
        $valid = $valid | append $right_line
        $right_line += 1
      } else if ($line | str starts-with '-') {
        # Deleted line — NOT a valid RIGHT line, don't increment right_line
        } else {
        # Context line (space or empty) — valid RIGHT line
        $valid = $valid | append $right_line
        $right_line += 1
      }
    }
  }
  $valid
}

# Build a concise review comment body from a finding section
# Extracts severity icon, problem description, and suggestion block
def build-review-comment-body [section: string] {
  let lines = $section | lines

  # Extract severity from heading line (### ❗ or ### ⚠️ or ### 💡)
  let heading_line = $lines | where { ($in | str starts-with '###') and ($in | str contains '`') } | get -o 0
  mut severity = ''
  if ($heading_line | is-not-empty) {
    if ($heading_line | str contains '❗') { $severity = '❗ Critical' }
    if ($heading_line | str contains '⚠️') { $severity = '⚠️ Warning' }
    if ($heading_line | str contains '💡') { $severity = '💡 Suggestion' }
  }

  # Extract problem description
  let desc_lines = $lines | where { $in | str contains '**问题描述：**' }
  let desc = if ($desc_lines | is-not-empty) {
    $desc_lines | first | str replace --regex '^.*\*\*问题描述：\*\*\s*' ''
  } else { '' }

  # Extract suggestion code
  let suggestion_code = extract-suggestion-code $lines

  # Build the comment body
  let parts = [
    $severity
    ''
    $desc
    ''
    '```suggestion'
    $suggestion_code
    '```'
  ]
  $parts | where { $in | is-not-empty } | str join "\n"
}

# Build a review comment body for findings WITHOUT suggestion block
# Only includes severity and description (no suggestion button)
def build-review-comment-body-no-suggestion [section: string] {
  let lines = $section | lines

  # Extract severity from heading line
  let heading_line = $lines | where { ($in | str starts-with '###') and ($in | str contains '`') } | get -o 0
  mut severity = ''
  if ($heading_line | is-not-empty) {
    if ($heading_line | str contains '❗') { $severity = '❗ Critical' }
    if ($heading_line | str contains '⚠️') { $severity = '⚠️ Warning' }
    if ($heading_line | str contains '💡') { $severity = '💡 Suggestion' }
  }

  # Extract problem description
  let desc_lines = $lines | where { $in | str contains '**问题描述：**' }
  let desc = if ($desc_lines | is-not-empty) {
    $desc_lines | first | str replace --regex '^.*\*\*问题描述：\*\*\s*' ''
  } else { '' }

  # Extract 建议修改 text (may be plain text without diff)
  let suggest_idx = try { $lines | enumerate | where { $in.item | str contains '**建议修改：**' } | get 0 | get index } catch { -1 }
  let suggest_text = if $suggest_idx >= 0 {
    # Take lines after 建议修改 until next section or empty
    let after = $lines | skip ($suggest_idx + 1)
    let relevant = $after | take while { $in | str starts-with '```' | not $in and ($in | str trim | is-not-empty) }
    $relevant | str join '\n'
  } else { '' }

  # Build the comment body without suggestion block
  let parts = [
    $severity
    ''
    $desc
  ]
  if ($suggest_text | is-not-empty) {
    $parts | append '' | append $suggest_text | str join "\n"
  } else {
    $parts | str join "\n"
  }
}

# Extract the code between ```suggestion and closing ```
# Cleans up any diff markers (-/+) that the AI may have mistakenly included
def extract-suggestion-code [lines: list] {
  let enumerated = $lines | enumerate
  # Find the line index of ```suggestion
  let start_entries = $enumerated | where { $in.item | str contains '```suggestion' }
  if ($start_entries | is-empty) { return '' }
  let start_idx = $start_entries | get 0 | get index
  # Find the next ``` after the start
  let after_start = $enumerated | where { $in.index > $start_idx }
  let end_entries = $after_start | where { $in.item | str starts-with '```' }
  let raw_lines = if ($end_entries | is-empty) {
    # No closing ```, take all remaining lines
    $lines | skip ($start_idx + 1)
  } else {
    let end_idx = $end_entries | get 0 | get index
    $lines | skip ($start_idx + 1) | take ($end_idx - $start_idx - 1)
  }
  # Clean diff markers: only strip lines matching diff+line_number format like '+ 42:    code' or '- 42:    code'
  # Do NOT strip bare +/- which may be legitimate code (e.g. Objective-C '- (void)method')
  $raw_lines | each {|line|
    $line | str replace --regex '^[+-]\s*\d+:\s+' ''
  } | str join "\n"
}

# Output the streaming response of review result from DeepSeek API
def streaming-output [
  url: string,        # The Full DeepSeek API URL
  payload: record,    # The payload to send to DeepSeek API
  --debug,            # Debug mode
  --headers: list,    # The headers to send to DeepSeek API
] {
  print -n (char nl)
  kv set content 0
  kv set reasoning 0
  http post -e -H $headers -t application/json $url $payload
    | tee {
        let res = $in
        let type = $res | describe
        let record_error = $type =~ '^record'
        let other_error  = $type =~ '^string' and $res !~ 'data: ' and $res !~ 'done'
        if $record_error or $other_error {
          $res | table -e | print
          exit $ECODE.SERVER_ERROR
        }
      }
    | try { lines } catch { print $'(ansi r)Error Happened ...(ansi reset)'; exit $ECODE.SERVER_ERROR }
    | each {|line|
        if ($line | is-empty) { return }
        if ($IGNORED_MESSAGES | get -o $line | default false) { return }
        let $last = $line | parse-line
        if $debug { $last | to json | kv set last-reply }
        $last | get -o choices.0.delta | default ($last | get -o message) | if ($in | is-not-empty) {
          let delta = $in
          if ($delta | coalesce-reasoning | is-not-empty) { kv set reasoning ((kv get reasoning) + 1) }
          if (kv get reasoning) == 1 { print $'(char nl)Reasoning Details:'; hr-line }
          if ($delta.content | is-not-empty) { kv set content ((kv get content) + 1) }
          if (kv get content) == 1 { print $'(char nl)Review Details:'; hr-line }
          print -n ($delta | coalesce-reasoning | default $delta.content)
        }
      }

  if $debug and (kv get last-reply | is-not-empty) {
    print $'(char nl)(char nl)Model & Token Usage:'; hr-line
    kv get last-reply | from json | select -o model usage | table -e | print
  }
}

# Parse the line from the streaming response
def parse-line [] {
  let $line = $in
  # DeepSeek Response vs Local Ollama Response
  try {
    if $line =~ '^data: ' {
      $line | str substring 6.. | from json
    } else {
      $line | from json
    }
  } catch {
    print -e $'(ansi r)Unrecognized content:(ansi reset) ($line)'
    exit $ECODE.SERVER_ERROR
  }
}

# Coalesce the reasoning content
def coalesce-reasoning [] {
  let msg = $in
  $msg.reasoning_content? | default $msg.reasoning?
}

# Build diff range summary string for terminal print
export def build-diff-range [setting: record] {
  let from = $setting.diff_from? | default ''
  let to = $setting.diff_to? | default ''
  let patch = $setting.patch_cmd? | default ''

  # For diff-from mode (diff_to defaults to HEAD)
  if ($from | is-not-empty) {
    let to_ref = if ($to | is-not-empty) { $to } else { 'HEAD' }
    let sha_from = try { git rev-parse --short $from | str trim } catch { $from }
    let sha_to = try { git rev-parse --short $to_ref | str trim } catch { $to_ref }
    let ref_info = if ($from | str starts-with $sha_from) and ($to_ref | str starts-with $sha_to) {
      ''  # Already SHAs, no need to show branch names
    } else {
      $' ($from)..($to_ref)'
    }
    return $'📐 对比范围：($sha_from) → ($sha_to)($ref_info)'
  }

  # For patch command mode (e.g. git show HEAD~1)
  if ($patch | is-not-empty) {
    return $'📐 对比命令：($patch)'
  }

  ''
}

alias main = deepseek-review
