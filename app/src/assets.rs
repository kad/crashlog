// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: MIT

//! Generation of the auxiliary files shipped alongside the `iclg` binary.
//!
//! Manual pages and shell completions are derived from the command line definition itself, so
//! that they never drift from the actual interface. Distribution packaging invokes this through
//! the hidden `iclg generate-assets` sub-command.

use clap::{Command, CommandFactory};
use clap_complete::Shell;
use clap_mangen::Man;
use std::fs;
use std::io;
use std::path::Path;

/// Shells for which completion scripts are generated.
const SHELLS: [Shell; 3] = [Shell::Bash, Shell::Zsh, Shell::Fish];

/// Name of the installed binary, which is also the name of the generated files.
///
/// It is set explicitly rather than taken from the command line definition, because the packaging
/// installs the generated files under this exact name.
const BINARY_NAME: &str = "iclg";

/// Writes the manual pages and the shell completion scripts into `output_dir`.
///
/// The directory is created if it does not exist yet. The following files are produced:
///
/// - `iclg.1` and one `iclg-<sub-command>.1` page per visible sub-command,
/// - `iclg.bash`, `_iclg` and `iclg.fish` completion scripts.
pub fn generate(output_dir: &Path) -> io::Result<()> {
    fs::create_dir_all(output_dir)?;

    let mut cmd = crate::Cli::command().name(BINARY_NAME);
    cmd.build();

    render_man_pages(&cmd, output_dir, "")?;

    for shell in SHELLS {
        clap_complete::generate_to(shell, &mut cmd, BINARY_NAME, output_dir)?;
    }

    Ok(())
}

/// Renders the manual page of `cmd` and recurses over its visible sub-commands.
///
/// Sub-command pages are named after their full command path, e.g. the `decode` sub-command of
/// `iclg` is documented in `iclg-decode.1`, following the convention used by most multi-call
/// command line tools.
fn render_man_pages(cmd: &Command, output_dir: &Path, prefix: &str) -> io::Result<()> {
    let name = if prefix.is_empty() {
        cmd.get_name().to_string()
    } else {
        format!("{prefix}-{}", cmd.get_name())
    };

    let mut page = Vec::new();
    Man::new(cmd.clone().name(name.clone())).render(&mut page)?;
    fs::write(output_dir.join(format!("{name}.1")), page)?;

    // `help` is synthesised by clap itself and documents nothing that the page of its parent does
    // not already cover, so it is skipped along with the sub-commands hidden from the help output.
    let subcommands = cmd
        .get_subcommands()
        .filter(|sub| !sub.is_hide_set() && sub.get_name() != "help");

    for sub in subcommands {
        render_man_pages(sub, output_dir, &name)?;
    }

    Ok(())
}
