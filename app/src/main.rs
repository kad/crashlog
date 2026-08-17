// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: MIT

mod analysis;
#[cfg(feature = "generate-assets")]
mod assets;
mod control;
mod decode;
mod extract;
mod info;
mod list;
mod table;
mod unpack;

use clap::{Parser, Subcommand, ValueEnum};
use env_logger::Env;
use intel_crashlog::prelude::*;
use log::LevelFilter;
use std::path::PathBuf;

#[derive(Parser)]
// The command name is set explicitly: clap derives it from the package name, which is
// `intel_crashlog_app`, while the installed binary and its manual pages are called `iclg`.
#[command(name = "iclg", version, about = "Extract and decode Intel Crash Log records.")]
pub(crate) struct Cli {
    /// Path to the collateral tree. If not specified, the builtin collateral tree will be used.
    #[arg(short, long, value_name = "dir")]
    collateral_tree: Option<PathBuf>,

    /// Sets the verbosity of the logging messages
    /// -v: Warning, -vv: Info, -vvv: Debug, -vvvv: Trace
    #[arg(short = 'v', long = "verbose", action = clap::ArgAction::Count)]
    verbosity: u8,

    #[command(subcommand)]
    command: Command,
}

#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Default, ValueEnum)]
pub(crate) enum InfoFormat {
    #[default]
    Compact,
    Markdown,
}

#[derive(Subcommand)]
enum Command {
    /// Enable Crash Log collection in the platform
    Enable {
        #[arg(short, long, value_delimiter = ',')]
        sources: Vec<CrashLogSource>,
    },
    /// Extract the Crash Log records from the platform
    Extract {
        output_path: Option<PathBuf>,
        #[arg(short, long, value_delimiter = ',')]
        sources: Vec<CrashLogSource>,
    },
    /// Decode Crash Log records into JSON
    Decode { input_file: PathBuf },
    /// Disable Crash Log collection in the platform
    Disable {
        #[arg(short, long, value_delimiter = ',')]
        sources: Vec<CrashLogSource>,
    },
    /// List the Crash Log records stored in the input file
    Info {
        #[arg(short, long, value_enum, default_value_t = InfoFormat::default())]
        format: InfoFormat,
        input_files: Vec<PathBuf>,
    },
    /// List the Crash Log sources that are available in the platform with their capabilities
    List,
    /// Trigger an on-demand Crash Log collection in the platform
    Trigger {
        #[arg(short, long, value_delimiter = ',')]
        sources: Vec<CrashLogSource>,
    },
    /// Clear the Crash Log storages
    Clear {
        #[arg(short, long, value_delimiter = ',')]
        sources: Vec<CrashLogSource>,
    },
    /// Unpack the Crash Log records stored in the input file
    Unpack { input_files: Vec<PathBuf> },
    /// Triage the Crash Log records stored in the input files
    Triage { input_files: Vec<PathBuf> },
    /// Generate the manual pages and the shell completion scripts
    ///
    /// This sub-command is meant to be used when packaging the application: it writes the
    /// manual pages and the shell completion scripts derived from this command line interface
    /// into the given directory.
    #[cfg(feature = "generate-assets")]
    #[command(hide = true)]
    GenerateAssets {
        /// Directory in which the generated files are written
        #[arg(short, long, value_name = "dir", default_value = ".")]
        output_dir: PathBuf,
    },
}

impl Command {
    fn run<T: CollateralTree>(&self, mut cm: CollateralManager<T>) -> Result<(), Error> {
        match self {
            Command::Enable { sources } => control::enable(sources.clone())?,
            Command::Extract {
                output_path,
                sources,
            } => extract::extract(output_path.as_deref(), sources.clone()),
            Command::Decode { input_file } => {
                decode::decode(&mut cm, input_file, std::io::stdout().lock())?
            }
            Command::Disable { sources } => control::disable(sources.clone())?,
            Command::Info {
                input_files,
                format,
            } => info::info(&cm, input_files, *format),
            Command::List => list::list(),
            Command::Trigger { sources } => control::trigger(sources.clone())?,
            Command::Clear { sources } => control::clear(sources.clone())?,
            Command::Unpack { input_files } => {
                for input_file in input_files {
                    if let Err(err) = unpack::unpack(input_file) {
                        log::error!("Error: {err}")
                    }
                }
            }
            Command::Triage { input_files } => analysis::triage_files(&mut cm, input_files),
            #[cfg(feature = "generate-assets")]
            Command::GenerateAssets { .. } => {
                unreachable!("handled before the collateral manager is created")
            }
        }
        Ok(())
    }
}

fn run(cli: Cli) -> Result<(), Error> {
    if let Some(collateral_tree) = cli.collateral_tree {
        cli.command
            .run(CollateralManager::file_system_tree(&collateral_tree)?)?
    } else {
        cli.command.run(CollateralManager::embedded_tree()?)?
    }
    Ok(())
}

fn main() {
    let cli = Cli::parse();

    let log_level = match cli.verbosity {
        0 => LevelFilter::Error,
        1 => LevelFilter::Warn,
        2 => LevelFilter::Info,
        3 => LevelFilter::Debug,
        _ => LevelFilter::Trace,
    };

    env_logger::Builder::from_env(Env::default().default_filter_or(log_level.to_string())).init();

    // Asset generation does not need any collateral, so it is handled before the collateral
    // manager is created.
    #[cfg(feature = "generate-assets")]
    if let Command::GenerateAssets { output_dir } = &cli.command {
        if let Err(err) = assets::generate(output_dir) {
            log::error!("Fatal Error: cannot generate the assets: {err}");
            std::process::exit(1);
        }
        return;
    }

    if let Err(err) = run(cli) {
        log::error!("Fatal Error: {err}");
        std::process::exit(1);
    }
}
