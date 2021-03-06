#!/usr/bin/env bash

# Stop script if unbound variable found (use ${var:-} if intentional)
set -u

# Initialize variables if they aren't already defined.

# CI mode - set to true on CI server for PR validation build or official build.
ci=${ci:-false}

# Build configuration. Common values include 'Debug' and 'Release', but the repository may use other names.
configuration=${configuration:-'Debug'}

# Set to true to output binary log from msbuild. Note that emitting binary log slows down the build.
# Binary log must be enabled on CI.
binary_log=${binary_log:-$ci}

# Turns on machine preparation/clean up code that changes the machine state (e.g. kills build processes).
prepare_machine=${prepare_machine:-false}

# True to restore toolsets and dependencies.
restore=${restore:-true}

# Adjusts msbuild verbosity level.
verbosity=${verbosity:-'minimal'}

# Set to true to reuse msbuild nodes. Recommended to not reuse on CI.
if [[ "$ci" == true ]]; then
  node_reuse=${node_reuse:-false}
else
  node_reuse=${node_reuse:-true}
fi

# Configures warning treatment in msbuild.
warn_as_error=${warn_as_error:-true}

# True to attempt using .NET Core already that meets requirements specified in global.json 
# installed on the machine instead of downloading one.
use_installed_dotnet_cli=${use_installed_dotnet_cli:-true}

# True to use global NuGet cache instead of restoring packages to repository-local directory.
if [[ "$ci" == true ]]; then
  use_global_nuget_cache=${use_global_nuget_cache:-false}
else
  use_global_nuget_cache=${use_global_nuget_cache:-true}
fi

# Resolve any symlinks in the given path.
function ResolvePath {
  local path=$1

  while [[ -h $path ]]; do
    local dir="$( cd -P "$( dirname "$path" )" && pwd )"
    path="$(readlink "$path")"

    # if $path was a relative symlink, we need to resolve it relative to the path where the
    # symlink file was located
    [[ $path != /* ]] && path="$dir/$path"
  done

  # return value
  _ResolvePath="$path"
}

# ReadVersionFromJson [json key]
function ReadGlobalVersion {
  local key=$1

  local line=`grep -m 1 "$key" "$global_json_file"`
  local pattern="\"$key\" *: *\"(.*)\""

  if [[ ! $line =~ $pattern ]]; then
    echo "Error: Cannot find \"$key\" in $global_json_file" >&2
    ExitWithExitCode 1
  fi

  # return value
  _ReadGlobalVersion=${BASH_REMATCH[1]}
}

function InitializeDotNetCli {
  if [[ -n "${_InitializeDotNetCli:-}" ]]; then
    return
  fi

  local install=$1

  # Don't resolve runtime, shared framework, or SDK from other locations to ensure build determinism
  export DOTNET_MULTILEVEL_LOOKUP=0

  # Disable first run since we want to control all package sources
  export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

  # Disable telemetry on CI
  if [[ $ci == true ]]; then
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
  fi

  # LTTNG is the logging infrastructure used by Core CLR. Need this variable set
  # so it doesn't output warnings to the console.
  export LTTNG_HOME="$HOME"

  # Source Build uses DotNetCoreSdkDir variable
  if [[ -n "${DotNetCoreSdkDir:-}" ]]; then
    export DOTNET_INSTALL_DIR="$DotNetCoreSdkDir"
  fi

  # Find the first path on $PATH that contains the dotnet.exe
  if [[ "$use_installed_dotnet_cli" == true && -z "${DOTNET_INSTALL_DIR:-}" ]]; then
    local dotnet_path=`command -v dotnet`
    if [[ -n "$dotnet_path" ]]; then
      ResolvePath "$dotnet_path"
      export DOTNET_INSTALL_DIR=`dirname "$_ResolvePath"`
    fi
  fi

  ReadGlobalVersion "dotnet"
  local dotnet_sdk_version=$_ReadGlobalVersion
  local dotnet_root=""

  # Use dotnet installation specified in DOTNET_INSTALL_DIR if it contains the required SDK version,
  # otherwise install the dotnet CLI and SDK to repo local .dotnet directory to avoid potential permission issues.
  if [[ -n "${DOTNET_INSTALL_DIR:-}" && -d "$DOTNET_INSTALL_DIR/sdk/$dotnet_sdk_version" ]]; then
    dotnet_root="$DOTNET_INSTALL_DIR"
  else
    dotnet_root="$repo_root/.dotnet"
    export DOTNET_INSTALL_DIR="$dotnet_root"

    if [[ ! -d "$DOTNET_INSTALL_DIR/sdk/$dotnet_sdk_version" ]]; then
      if [[ "$install" == true ]]; then
        InstallDotNetSdk "$dotnet_root" "$dotnet_sdk_version"
      else
        echo "Unable to find dotnet with SDK version '$dotnet_sdk_version'" >&2
        ExitWithExitCode 1
      fi
    fi
  fi

  # Add dotnet to PATH. This prevents any bare invocation of dotnet in custom
  # build steps from using anything other than what we've downloaded.
  export PATH="$dotnet_root:$PATH"

  curl --retry 10 -s -SL -f --create-dirs -o $DOTNET_INSTALL_DIR/buildtools.tar.gz https://aspnetcore.blob.core.windows.net/buildtools/netfx/4.6.1/netfx.4.6.1.tar.gz
  [ -d "$DOTNET_INSTALL_DIR/buildtools/net461" ] || mkdir -p $DOTNET_INSTALL_DIR/buildtools/net461
  tar -zxf $DOTNET_INSTALL_DIR/buildtools.tar.gz -C $DOTNET_INSTALL_DIR/buildtools/net461

  export ReferenceAssemblyRoot=$DOTNET_INSTALL_DIR/buildtools/net461
  
  # return value
  _InitializeDotNetCli="$dotnet_root"
}

function InstallDotNetSdk {
  local root=$1
  local version=$2

  GetDotNetInstallScript "$root"
  local install_script=$_GetDotNetInstallScript

  bash "$install_script" --version $version --install-dir "$root"
  local lastexitcode=$?

  if [[ $lastexitcode != 0 ]]; then
    echo "Failed to install dotnet SDK (exit code '$lastexitcode')." >&2
    ExitWithExitCode $lastexitcode
  fi
}

function GetDotNetInstallScript {
  local root=$1
  local install_script="$root/dotnet-install.sh"
  local install_script_url="https://dot.net/v1/dotnet-install.sh"

  if [[ ! -a "$install_script" ]]; then
    mkdir -p "$root"

    echo "Downloading '$install_script_url'"

    # Use curl if available, otherwise use wget
    if command -v curl > /dev/null; then
      curl "$install_script_url" -sSL --retry 10 --create-dirs -o "$install_script"
    else
      wget -q -O "$install_script" "$install_script_url"
    fi
  fi

  # return value
  _GetDotNetInstallScript="$install_script"
}

function InitializeBuildTool {
  if [[ -n "${_InitializeBuildTool:-}" ]]; then
    return
  fi
  
  InitializeDotNetCli $restore

  # return value
  _InitializeBuildTool="$_InitializeDotNetCli/dotnet"  
}

function GetNuGetPackageCachePath {
  if [[ -z ${NUGET_PACKAGES:-} ]]; then
    if [[ "$use_global_nuget_cache" == true ]]; then
      export NUGET_PACKAGES="$HOME/.nuget/packages"
    else
      export NUGET_PACKAGES="$repo_root/.packages"
    fi
  fi

  # return value
  _GetNuGetPackageCachePath=$NUGET_PACKAGES
}

function InitializeToolset {
  if [[ -n "${_InitializeToolset:-}" ]]; then
    return
  fi

  GetNuGetPackageCachePath

  ReadGlobalVersion "Microsoft.DotNet.Arcade.Sdk"

  local toolset_version=$_ReadGlobalVersion
  local toolset_location_file="$toolset_dir/$toolset_version.txt"

  if [[ -a "$toolset_location_file" ]]; then
    local path=`cat "$toolset_location_file"`
    if [[ -a "$path" ]]; then
      # return value
      _InitializeToolset="$path"
      return
    fi
  fi

  if [[ "$restore" != true ]]; then
    echo "Toolset version $toolsetVersion has not been restored." >&2
    ExitWithExitCode 2
  fi

  local toolset_restore_log="$log_dir/ToolsetRestore.binlog"
  local proj="$toolset_dir/restore.proj"

  echo '<Project Sdk="Microsoft.DotNet.Arcade.Sdk"/>' > "$proj"
  MSBuild "$proj" /t:__WriteToolsetLocation /noconsolelogger /bl:"$toolset_restore_log" /p:__ToolsetLocationOutputFile="$toolset_location_file"

  local toolset_build_proj=`cat "$toolset_location_file"`

  if [[ ! -a "$toolset_build_proj" ]]; then
    echo "Invalid toolset path: $toolset_build_proj" >&2
    ExitWithExitCode 3
  fi

  # return value
  _InitializeToolset="$toolset_build_proj"
}

function ExitWithExitCode {
  if [[ "$ci" == true && "$prepare_machine" == true ]]; then
    StopProcesses
  fi
  exit $1
}

function StopProcesses {
  echo "Killing running build processes..."
  pkill -9 "dotnet"
  pkill -9 "vbcscompiler"
  return 0
}

function MSBuild {
  if [[ "$ci" == true ]]; then
    if [[ "$binary_log" != true ]]; then
      echo "Binary log must be enabled in CI build." >&2
      ExitWithExitCode 1
    fi

    if [[ "$node_reuse" == true ]]; then
      echo "Node reuse must be disabled in CI build." >&2
      ExitWithExitCode 1
    fi
  fi

  InitializeBuildTool

  local warnaserror_switch=""
  if [[ $warn_as_error == true ]]; then
    warnaserror_switch="/warnaserror"
  fi

  "$_InitializeBuildTool" msbuild /m /nologo /clp:Summary /v:$verbosity /nr:$node_reuse $warnaserror_switch /p:TreatWarningsAsErrors=$warn_as_error "$@"
  lastexitcode=$?

  if [[ $lastexitcode != 0 ]]; then
    echo "Build failed (exit code '$lastexitcode')." >&2
    ExitWithExitCode $lastexitcode
  fi
}

ResolvePath "${BASH_SOURCE[0]}"
_script_dir=`dirname "$_ResolvePath"`

eng_root=`cd -P "$_script_dir/.." && pwd`
repo_root=`cd -P "$_script_dir/../.." && pwd`
artifacts_dir="$repo_root/artifacts"
toolset_dir="$artifacts_dir/toolset"
log_dir="$artifacts_dir/log/$configuration"
temp_dir="$artifacts_dir/tmp/$configuration"

global_json_file="$repo_root/global.json"

# HOME may not be defined in some scenarios, but it is required by NuGet
if [[ -z $HOME ]]; then
  export HOME="$repo_root/artifacts/.home/"
  mkdir -p "$HOME"
fi

mkdir -p "$toolset_dir"
mkdir -p "$temp_dir"
mkdir -p "$log_dir"

if [[ $ci == true ]]; then
  export TEMP="$temp_dir"
  export TMP="$temp_dir"
fi
