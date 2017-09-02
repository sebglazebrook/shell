#!/usr/bin/env ruby

require "readline"
require "parslet"

# PEG (Parsing Expression Grammar)

def last_stdout_filename
  Dir["#{ENV["HOME"]}/.infinite-pipe/stdout-history/*"].last
end

def next_stdout_filename
  "#{ENV["HOME"]}/.infinite-pipe/stdout-history/#{Time.now.to_i}.stdout"
end

def last_saved_stdout
  if last_stdout_filename
    File.open(last_stdout_filename, "r").read
  else
    ""
  end
end

def main
  `mkdir -p ~/.infinite-pipe/stdout-history`
  loop do
    cmdline = Readline.readline("$ ", true)
    tree = parse_cmdline(cmdline)
    pids = tree.execute($stdin.fileno, $stdout.fileno)
    pids.each do |pid|
      Process.wait(pid)
    end
  end
end

def parse_cmdline(cmdline)
  raw_tree = Parser.new.parse(cmdline)
  Transform.new.apply(raw_tree)
end

class Parser < Parslet::Parser

  root :cmdline

  rule(:cmdline) { pipeline_continued | command_continued | pipeline | command }

  rule(:pipeline) { command.as(:left) >> pipe.as(:pipe) >> cmdline.as(:right) }
  rule(:pipeline_continued) { pipe.as(:continued_pipe) >> pipeline }
  rule(:pipe) {  str("|") >> space? }

  rule(:command) { arg.as(:arg).repeat(1).as(:command) }
  rule(:command_continued) { pipe.as(:continued_command) >> command }

  rule(:arg) { unquoted_arg | single_quoted_arg }
  rule(:unquoted_arg) { match[%q{^\s'|}].repeat(1) >> space? }
  rule(:single_quoted_arg) { str("'").ignore  >> match[%q{^'}].repeat(0) >> str("'").ignore >> space? }

  rule(:space?) { space.maybe }
  rule(:space) { match[%q{\s}].repeat(1).ignore }

end

class Transform < Parslet::Transform

  rule(left: subtree(:left), pipe: "|", right: subtree(:right)) { Pipeline.new(left, right) }
  rule(continued_pipe: subtree(:continued_pipe), left: subtree(:left), pipe: "|", right: subtree(:right)) { ContinuedPipeline.new(left, right) }

  rule(command: sequence(:args)) { Command.new(args) }
  rule(continued_command: subtree(:continued_pipe), command: sequence(:args)) { ContinuedCommand.new(args) }

  rule(arg: simple(:arg)) { arg }

end

class ContinuedCommand

  def initialize(args)
    @args = args
  end

  def execute(stdin, stdout)
    reader, writer = IO.pipe
    writer.write(last_saved_stdout)
    writer.close
    pids = [spawn(*@args, 0 => reader.fileno, 1 => stdout)]
    reader.close
    pids
  end


end

class ContinuedPipeline

  def initialize(left, right)
    @left = left
    @right = right
  end

  def execute(stdin, stdout)
    reader, writer = IO.pipe
    old_reader, old_writer = IO.pipe
    old_writer.write(last_saved_stdout)
    old_writer.close
    pids  = @left.execute(old_reader.fileno, writer.fileno) + @right.execute(reader.fileno, stdout)
    old_reader.close
    reader.close
    writer.close
    pids
  end

end

class Pipeline

  def initialize(left, right)
    @left = left
    @right = right
  end

  def execute(stdin, stdout)
    reader, writer = IO.pipe
    pids  = @left.execute(stdin, writer.fileno) + @right.execute(reader.fileno, stdout)
    reader.close
    writer.close
    pids
  end

end

class Command 

  def initialize(args)
    @args = args
  end

  def execute(stdin, stdout)
    if stdout != 1
      [spawn(*@args, 0 => stdin, 1 => stdout)]
    else
      reader, writer = IO.pipe
      pids = [spawn(*@args, 0 => stdin, 1 => writer.fileno)]
      writer.close
      output = reader.read
      reader.close
      $stdout.puts(output)
      File.open(next_stdout_filename, "w") { |file| file.write(output) }
      # TODO only save as many stdouts as the user had configured
      pids
    end
  end

end

main
