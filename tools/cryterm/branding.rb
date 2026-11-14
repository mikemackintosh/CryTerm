#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Keeps the name “iTerm2” out of CryTerm's user interface.
#
#   tools/cryterm/branding.rb check   # list offending lines; exit 1 if any
#   tools/cryterm/branding.rb fix     # rename what is safe to rename, list the rest
#
# Run `fix` after merging from upstream iTerm2: upstream adds new strings and
# translations that say iTerm2. `check` runs in CI on every push and PR.
#
# What counts as user-visible text:
#   * string catalogs (.xcstrings): translated values and keys (never comments)
#   * Interface Builder files: every attribute and element text, except
#     identifiers
#   * Swift, Objective-C, C, and JavaScript: string literals (including Swift
#     multi-line literals), outside comment lines
#   * HTML, plists, the AppleScript dictionary: every non-comment line
#
# What `fix` renames by itself: catalog keys and values, Interface Builder
# text, and string literals in localization calls (NSLocalizedString…,
# String(localized:…), defaultValue:). Other string literals are often file
# names, protocol strings, or log prefixes, so `fix` lists them for a person to
# decide: either change the source, or add the line to
# tools/cryterm/branding-allowlist.txt.
#
# Never renamed: “iTerm2 Buddy” (the name of upstream's iPhone app, also as
# “iTerm2-Buddy” in German compounds), URLs and identifiers (iTerm2 preceded by
# / . @ - or a word character, or followed by a word character), and anything
# the allowlist covers, including every string of an allowlisted catalog key
# wherever its source code names that key.

require 'open3'

ROOT = File.expand_path('../..', __dir__)
ALLOWLIST_PATH = File.join(ROOT, 'tools/cryterm/branding-allowlist.txt')

SCANNED_PATHS = %w[sources xcstrings plists iTerm2.sdef].freeze

NAME = /(?<![A-Za-z0-9_\/.@-])iTerm2(?![A-Za-z0-9_]|[ -]Buddy)/.freeze
NEW_NAME = 'CryTerm'

LITERAL_EXTENSIONS = %w[.swift .m .mm .h .c .js].freeze
WHOLE_LINE_EXTENSIONS = %w[.html .htm .plist .sdef .strings].freeze
IB_EXTENSIONS = %w[.xib .storyboard].freeze

LOCALIZATION_CALL = /NSLocalizedString|String\(localized:|defaultValue:|LocalizedStringResource|localizedStringWithFormat/.freeze
# The catalog key named on a source line, as in NSLocalizedStringWithDefaultValue(@"Key", …)
# or String(localized: "Key", …).
LOCALIZATION_KEY = /(?:NSLocalizedStringWithDefaultValue\(@|NSLocalizedString\(@|String\(localized:\s*)"((?:[^"\\]|\\.)*)"/.freeze
STRING_LITERAL = /"(?:[^"\\]|\\.)*"/.freeze

Finding = Struct.new(:path, :line_number, :text, :fixable, keyword_init: true)

class Allowlist
  def initialize(path)
    @files = []
    @lines = {}
    @keys = []
    File.readlines(path, chomp: true).each_with_index do |raw, index|
      next if raw.strip.empty? || raw.start_with?('#')
      kind, rest = raw.split(' ', 2)
      case kind
      when 'file'
        @files << rest.strip
      when 'key'
        @keys << Regexp.new(rest.strip)
      when 'line'
        path, text = rest.split("\t", 2)
        abort "#{path}:#{index + 1}: a line entry needs a tab between path and text" unless text
        (@lines[path] ||= []) << text.strip
      else
        abort "#{ALLOWLIST_PATH}:#{index + 1}: unknown entry kind #{kind.inspect}"
      end
    end
    @used_lines = Hash.new { |h, k| h[k] = [] }
  end

  def file?(path)
    @files.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME) }
  end

  def key?(key)
    @keys.any? { |pattern| pattern.match?(key) }
  end

  def line?(path, text)
    entries = @lines[path]
    return false unless entries&.include?(text.strip)
    @used_lines[path] << text.strip
    true
  end

  # Line entries that no longer match anything, so the allowlist doesn't rot.
  def stale_lines
    @lines.flat_map do |path, texts|
      (texts - @used_lines[path]).map { |text| "#{path}\t#{text}" }
    end
  end
end

def tracked_files
  out, status = Open3.capture2('git', '-C', ROOT, 'ls-files', '-z', '--', *SCANNED_PATHS)
  abort 'git ls-files failed' unless status.success?
  out.split("\0")
end

def name_in?(text)
  NAME.match?(text)
end

def literals_with_name(line)
  line.scan(STRING_LITERAL).select { |literal| name_in?(literal) }
end

def comment_line?(line, extension)
  stripped = line.lstrip
  case extension
  when *LITERAL_EXTENSIONS
    stripped.start_with?('//', '/*', '* ', '*/') || stripped == '*'
  when '.html', '.htm', '.plist', '.sdef'
    stripped.start_with?('<!--')
  else
    false
  end
end

def scan_catalog(path, lines, allowlist, findings)
  key = nil
  lines.each_with_index do |line, index|
    if (match = line.match(/\A {4}"((?:[^"\\]|\\.)*)" : \{/))
      key = match[1]
      next if allowlist.key?(key)
      if name_in?(key) && !allowlist.line?(path, line)
        findings << Finding.new(path: path, line_number: index + 1, text: line, fixable: true)
      end
      next
    end
    next unless line.match?(/\A\s*"value" : "/)
    next if key && allowlist.key?(key)
    next unless name_in?(line)
    next if allowlist.line?(path, line)
    findings << Finding.new(path: path, line_number: index + 1, text: line, fixable: true)
  end
end

def scan_interface_builder(path, lines, allowlist, findings)
  lines.each_with_index do |line, index|
    visible = line.gsub(/\b(?:identifier|id|customClass|customModule|key|userLabel)="[^"]*"/, '')
    next unless name_in?(visible)
    next if allowlist.line?(path, line)
    findings << Finding.new(path: path, line_number: index + 1, text: line, fixable: true)
  end
end

def scan_source(path, lines, allowlist, findings)
  extension = File.extname(path)
  in_multiline_literal = false
  lines.each_with_index do |line, index|
    delimiters = extension == '.swift' ? line.scan('"""').length : 0
    if in_multiline_literal
      in_multiline_literal = !delimiters.odd?
      next unless name_in?(line)
    else
      in_multiline_literal = delimiters.odd?
      next if comment_line?(line, extension)
      next if literals_with_name(line).empty? && !(in_multiline_literal && name_in?(line))
    end
    context = lines[[index - 4, 0].max..index].join("\n")
    named_key = context.scan(LOCALIZATION_KEY).flatten.last
    next if named_key && allowlist.key?(named_key)
    next if allowlist.line?(path, line)
    findings << Finding.new(path: path, line_number: index + 1, text: line,
                            fixable: LOCALIZATION_CALL.match?(context))
  end
end

def scan_whole_lines(path, lines, allowlist, findings)
  extension = File.extname(path)
  lines.each_with_index do |line, index|
    next if comment_line?(line, extension)
    next unless name_in?(line)
    next if allowlist.line?(path, line)
    findings << Finding.new(path: path, line_number: index + 1, text: line, fixable: false)
  end
end

def scan(allowlist)
  findings = []
  tracked_files.each do |path|
    next if allowlist.file?(path)
    full_path = File.join(ROOT, path)
    next unless File.file?(full_path)
    content = File.read(full_path, encoding: 'UTF-8')
    next unless content.valid_encoding? && content.include?('iTerm2')
    lines = content.split("\n", -1)
    case File.extname(path)
    when '.xcstrings' then scan_catalog(path, lines, allowlist, findings)
    when *IB_EXTENSIONS then scan_interface_builder(path, lines, allowlist, findings)
    when *LITERAL_EXTENSIONS then scan_source(path, lines, allowlist, findings)
    when *WHOLE_LINE_EXTENSIONS then scan_whole_lines(path, lines, allowlist, findings)
    end
  end
  findings
end

def rename(line)
  line.gsub(NAME, NEW_NAME)
end

def apply_fixes(findings)
  findings.select(&:fixable).group_by(&:path).each do |path, file_findings|
    full_path = File.join(ROOT, path)
    lines = File.read(full_path, encoding: 'UTF-8').split("\n", -1)
    file_findings.each do |finding|
      index = finding.line_number - 1
      lines[index] = if File.extname(path) == '.xcstrings' || IB_EXTENSIONS.include?(File.extname(path))
                       rename(lines[index])
                     else
                       rename_literals(lines[index])
                     end
    end
    File.write(full_path, lines.join("\n"))
  end
end

# In source files, rename only inside string literals, so code on the same
# line (identifiers, comments) is untouched. A line inside a Swift multi-line
# literal has no quotes and is renamed whole.
def rename_literals(line)
  return rename(line) unless line.include?('"')
  line.gsub(STRING_LITERAL) { |literal| rename(literal) }
end

def report(findings, heading)
  return if findings.empty?
  puts heading
  findings.each { |f| puts "  #{f.path}:#{f.line_number}: #{f.text.strip[0, 200]}" }
end

mode = ARGV.fetch(0, 'check')
abort "usage: #{$PROGRAM_NAME} check|fix" unless %w[check fix].include?(mode)

allowlist = Allowlist.new(ALLOWLIST_PATH)
findings = scan(allowlist)

if mode == 'fix'
  fixed = findings.select(&:fixable)
  apply_fixes(fixed)
  puts "Renamed iTerm2 to CryTerm on #{fixed.length} line(s)." unless fixed.empty?
  allowlist = Allowlist.new(ALLOWLIST_PATH)
  findings = scan(allowlist)
end

review = findings.reject(&:fixable)
report(findings.select(&:fixable), 'User-visible text says iTerm2 (`tools/cryterm/branding.rb fix` renames these):')
report(review, 'Says iTerm2; decide by hand, then change it or add it to tools/cryterm/branding-allowlist.txt:')
stale = allowlist.stale_lines
unless stale.empty?
  puts 'Allowlist lines that match nothing any more (delete them from tools/cryterm/branding-allowlist.txt):'
  stale.each { |line| puts "  line #{line}" }
end
if findings.empty? && stale.empty?
  puts 'No user-visible iTerm2 found.'
  exit 0
end
exit 1
