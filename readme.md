# dmsbuild

This is a toy program that helps locating msbuild executable in various windows environments.

## Overview

dmsbuild searches for msbuild in the following order:

1. Using vswhere utiity (2017+)
2. Using Windows registry (2015, 2013)
3. .NET Framework (4.0, 3.5, 2.0)

It tries to use the latest msbuild that matches version the solution file from the command line.

You can also supply --all switch that will display all detectable versions (both x64 and x86) of 
msbuild on your computer. 

## Usage

```sh
Usage: dmsuild [dmsbuild args] [msbuild.exe args]
----------
Arguments:
----------
 --no-vs             - Disable searching in Visual Studio folder.
 --no-netfx          - Disable searching in .NET Framework folder.
 --no-vswhere        - Do not search via vswhere.

 --vsw-require {IDs} - Non-strict components preference: https://aka.ms/vs/workloads
                       Comma-separated list.

 --all               - Collects info about all msbuild versions.
 --no-cache          - Do not cache vswhere for this request.
 --reset-cache       - Reset all cached vswhere versions before processing.
 --no-amd64          - Use 32-bit version of msbuild.exe.
 --prerelease        - Include possible beta releases.
 --print-path        - Display full path to msbuild.exe and exit.
 --debug             - Show dmsbuild diagnostic information.
 --version           - Display version of dmsbuild.
 --help              - Display this help.


--------
Samples:
--------
dmsbuild --no-amd64 "UE4.sln" /t:rebuild /p:configuration="Development Editor"

dmsbuild --no-vswhere --no-vs --no-amd64 "UE4.sln"
dmsbuild --no-vs "UE4.sln"
```

## Building

```sh
> dub build --arch=x86_64 --build=release
> dub build --arch=x86 --build=release
```

## Formatting

```sh
> dfmt --inplace --max_line_length=120 --soft_max_line_length=100 --brace_style=allman source/main.d
```

## Inspiration

Main drivers for its creation were:

* desire to test D as scripting language
* issues finding msbuild.exe on bunch of new computers

There exists batch file with somewhat similar functionality: [hMSBuild](https://github.com/3F/hMSBuild)


