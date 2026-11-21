default: test

alias c := check

check: && format
    yamllint .
    luacheck .
    nix flake check

alias f := format
alias fmt := format

format:
    treefmt

alias t := test

test:
    luajit test/test_breaktimer.lua
    lua test/test_breaktimer.lua

alias u := update
alias up := update

update:
    nix run ".#update-nix-direnv"
    nix run ".#update-nixos-release"
    nix flake update
