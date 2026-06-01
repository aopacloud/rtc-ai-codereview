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
  # Build diff range summary for terminal print
  let diff_range = build-diff-range $setting

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

  # Print diff range info in terminal
  if ($diff_range | is-not-empty) {
    print $'(char nl)($diff_range)'
  }

  if ($response.usage? | is-not-empty) {
    print $'(char nl)Token Usage:'; hr-line
    $response.usage? | table -e | print
  }
}

# Write the code review result to a file
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

  # 1. Post the full review as an issue comment
  let comment_url = $'($GITHUB_API_BASE)/repos/($repo)/issues/($pr_number)/comments'
  try {
    http post -t application/json -H $BASE_HEADER $comment_url { body: $comments }
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
    print $'  ⚠️ Failed to fetch PR data for commit_id: ($err.msg? | default $err)'
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

  for finding in $findings {
    let payload = {
      path: $finding.path
      line: $finding.line
      side: 'RIGHT'
      body: $finding.body
    }
    # Include commit_id if available for accurate diff positioning
    let payload = if ($commit_id | is-not-empty) {
      $payload | merge { commit_id: $commit_id }
    } else {
      $payload
    }
    try {
      http post -t application/json -H $BASE_HEADER $review_comment_url $payload
      print $'  ✅ Posted review comment on ($finding.path):($finding.line)'
    } catch {|err|
      let err_msg = $err.msg? | default ($err | str substring 0..<200)
      print $'  ⚠️ Skipped review comment on ($finding.path):($finding.line) - ($err_msg)'
    }
  }
}

# Parse the AI review response to extract findings with suggestion blocks
# Each finding includes: path, line, and body (with suggestion block)
def parse-findings [review: string] {
  # Split by section separator ---
  let sections = $review | split row '---' | where { $in | str trim | is-not-empty }

  $sections | each {|section|
    let trimmed = $section | str trim

    # Extract file path and line number from ### [severity] `path:line`
    # Find the heading line with `path:line` pattern (### ❗ `file/path:line` 🔴)
    let heading_lines = $trimmed | lines | where { ($in | str starts-with '###') and ($in | str contains '`') }
    if ($heading_lines | is-empty) { return }
    let heading_line = $heading_lines | first
    # Extract content between backticks
    let file_ref = $heading_line | str replace --regex '.*?`([^`]+)`.*' '$1'
    let parts = $file_ref | split row ':'
    if ($parts | length) < 2 { return }
    let path = $parts | get 0 | str trim
    # Handle line ranges like :178-185, take first line number
    let line_part = $parts | get 1 | split row '-' | get 0 | str trim
    let line = try { $line_part | into int } catch { return }

    # Check for suggestion block
    let has_suggestion = ($trimmed | str contains '```suggestion')
    if not $has_suggestion { return }

    # Build the review comment body (priority + description + suggestion)
    let body = build-review-comment-body $trimmed

    { path: $path, line: $line, body: $body }
  } | where { $in | is-not-empty }
}

# Build a concise review comment body from a finding section
# Extracts severity icon, problem description, and suggestion block
def build-review-comment-body [section: string] {
  let lines = $section | lines

  # Extract severity from heading line (### ❗ or ### ⚠️ or ### 💡)
  let heading_line = $lines | where { ($in | str starts-with '###') and ($in | str contains '`') } | get -o 0
  let severity = if ($heading_line | is-not-empty) {
    if ($heading_line | str contains '❗') { '❗ Critical' }
    else if ($heading_line | str contains '⚠️') { '⚠️ Warning' }
    else if ($heading_line | str contains '💡') { '💡 Suggestion' }
    else { '' }
  } else { '' }

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

# Extract the code between ```suggestion and closing ```
def extract-suggestion-code [lines: list] {
  let enumerated = $lines | enumerate
  # Find the line index of ```suggestion
  let start_entries = $enumerated | where { $in.item | str contains '```suggestion' }
  if ($start_entries | is-empty) { return '' }
  let start_idx = $start_entries | get 0 | get index
  # Find the next ``` after the start
  let after_start = $enumerated | where { $in.index > $start_idx }
  let end_entries = $after_start | where { $in.item | str starts-with '```' }
  if ($end_entries | is-empty) {
    # No closing ```, take all remaining lines
    $lines | skip ($start_idx + 1) | str join "\n"
  } else {
    let end_idx = $end_entries | get 0 | get index
    $lines | skip ($start_idx + 1) | take ($end_idx - $start_idx - 1) | str join "\n"
  }
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
