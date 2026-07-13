# Homebrew formula for AgentKit.
#
# This repository doubles as its own Homebrew tap. Install with:
#
#   brew tap utmostcreator/agent-kit https://github.com/UtmostCreator/agent-kit
#   brew install --HEAD agent-kit
#
# Until a tagged release is published, install from main:
#
#   brew install --HEAD agent-kit
class AgentKit < Formula
  desc "Safety-first CLI toolkit that gives coding agents a controlled repository interface"
  homepage "https://github.com/UtmostCreator/agent-kit"
  license "Apache-2.0"
  head "https://github.com/UtmostCreator/agent-kit.git", branch: "main"

  # macOS ships Bash 3.2; the toolkit needs Bash >= 4.4 (associative arrays,
  # mapfile). Depend on the brewed bash and point the wrapper at it explicitly.
  depends_on "bash"
  depends_on "git"
  depends_on "jq"
  depends_on "ripgrep"

  def install
    libexec.install "bin", "lib", "libexec", "share", "VERSION"
    libexec.install "hooks" if File.directory?("hooks")
    (bin/"agent-kit").write <<~SH
      #!/bin/bash
      exec "#{Formula["bash"].opt_bin}/bash" "#{libexec}/bin/agent-kit" "$@"
    SH
  end

  test do
    # Exercise the dispatcher AND a real subcommand, so the smoke test actually
    # runs a module under the resolved Bash (catches a Bash-version regression).
    assert_match "Available commands", shell_output("#{bin}/agent-kit --list")
    assert_match "Usage", shell_output("#{bin}/agent-kit search --help")
    assert_match(/"status"\s*:\s*"ok"/, shell_output("AI_OUTPUT=json #{bin}/agent-kit search doctor"))
  end
end
