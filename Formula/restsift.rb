# Homebrew formula for RestSift.
#
# This repository doubles as its own Homebrew tap. Install with:
#
#   brew tap utmostcreator/restsift https://github.com/UtmostCreator/restsift
#   brew install --HEAD restsift
#
# Until a tagged release is published, install from main:
#
#   brew install --HEAD restsift
class Restsift < Formula
  desc "Safety-first CLI toolkit that gives coding agents a controlled repository interface"
  homepage "https://github.com/UtmostCreator/restsift"
  license "Apache-2.0"
  head "https://github.com/UtmostCreator/restsift.git", branch: "main"

  # macOS ships Bash 3.2; the toolkit needs Bash >= 4.4 (associative arrays,
  # mapfile). Depend on the brewed bash and point the wrapper at it explicitly.
  depends_on "bash"
  depends_on "git"
  depends_on "jq"
  depends_on "ripgrep"

  def install
    libexec.install "bin", "lib", "libexec", "share", "completions", "VERSION"
    libexec.install "hooks" if File.directory?("hooks")
    # The canonical `restsift` and its new short alias `res` point straight at
    # the dispatcher under the brewed Bash (e.g. `res s TODO`).
    %w[restsift res].each do |name|
      (bin/name).write <<~SH
        #!/bin/bash
        exec "#{Formula["bash"].opt_bin}/bash" "#{libexec}/bin/restsift" "$@"
      SH
    end
    # The deprecated `agent-kit`/`ak` compatibility aliases forward through
    # their own warn-then-exec shim so they emit a deprecation notice on stderr.
    %w[agent-kit ak].each do |name|
      (bin/name).write <<~SH
        #!/bin/bash
        exec "#{Formula["bash"].opt_bin}/bash" "#{libexec}/bin/#{name}" "$@"
      SH
    end

    # Wire the generated, committed completion files into Homebrew's own
    # shell-completion directories so `restsift`/`res` complete out of the box
    # (no `restsift completion install` step required for Homebrew installs).
    bash_completion.install "completions/restsift.bash" => "restsift"
    zsh_completion.install "completions/_restsift"
    fish_completion.install "completions/restsift.fish"
  end

  test do
    # Exercise the dispatcher AND a real subcommand, so the smoke test actually
    # runs a module under the resolved Bash (catches a Bash-version regression).
    assert_match "Available commands", shell_output("#{bin}/restsift --list")
    assert_match "Usage", shell_output("#{bin}/restsift search --help")
    assert_match(/"status"\s*:\s*"ok"/, shell_output("AI_OUTPUT=json #{bin}/restsift search doctor"))
    # The short alias resolves to the same dispatcher.
    assert_match "Available commands", shell_output("#{bin}/ak --list")
  end
end
