#!/usr/bin/env perl

use strict;
use warnings;

my ($release_root, $jobs_dir);
while (@ARGV) {
    my $argument = shift @ARGV;
    if ($argument eq "--release-root") {
        $release_root = shift @ARGV;
    } elsif ($argument eq "--jobs-dir") {
        $jobs_dir = shift @ARGV;
    } else {
        die "unknown argument: $argument\n";
    }
}
die "--release-root is required\n" unless defined $release_root;
chdir $release_root or die "could not enter release root $release_root: $!\n";
chomp($release_root = `pwd`);
$jobs_dir //= "$release_root/ci-operator/jobs";

sub read_file {
    my ($path) = @_;
    open my $handle, "<", $path or die "could not read $path: $!\n";
    local $/;
    return <$handle>;
}

sub write_file {
    my ($path, $content) = @_;
    open my $handle, ">", $path or die "could not write $path: $!\n";
    print {$handle} $content;
    close $handle or die "could not close $path: $!\n";
}

sub find_files {
    my ($root, $pattern) = @_;
    open my $finder, "-|", "find", $root, "-type", "f", "-name", $pattern
      or die "could not search $root: $!\n";
    my @paths = <$finder>;
    close $finder or die "could not search $root\n";
    chomp @paths;
    return @paths;
}

my $manifest_relative = "hack/devcontainer-dependency-report-source-files.txt";
my @source_files = grep { length } split /\n/, read_file("$release_root/$manifest_relative");
die "release source manifest is empty\n" unless @source_files;
my %seen;
for my $path (@source_files) {
    die "invalid release source path: $path\n"
      if $path =~ m{(?:^|/)\.\.(?:/|$)} || $path =~ m{^/} || $path !~ m{\A[0-9A-Za-z._/-]+\z};
    die "duplicate release source path: $path\n" if $seen{$path}++;
    die "release source file does not exist: $path\n" unless -f "$release_root/$path";
}
unshift @source_files, $manifest_relative;

my @targets;
for my $path (find_files("$release_root/ci-operator/config", "*.yaml")) {
    my @lines = split /\n/, read_file($path);
    my $test;
    for my $line (@lines) {
        $test = $1 if $line =~ /^- as: (\S+)$/;
        push @targets, $test
          if defined $test
          && $line eq "    workflow: openshift-devcontainer-dependency-report";
    }
}
die "no dependency report periodics found\n" unless @targets;

my @job_files = find_files($jobs_dir, "*-periodics.yaml");
my %target_seen;
die "duplicate dependency report periodic target\n" if grep { $target_seen{$_}++ } @targets;
my $changed = 0;
for my $target (@targets) {
    my @matches = grep { read_file($_) =~ /^\s+- --target=\Q$target\E\s*$/m } @job_files;
    die "expected one generated periodic for $target, found " . scalar(@matches) . "\n"
      unless @matches == 1;
    my $path = $matches[0];
    my @lines = split /(?<=\n)/, read_file($path);
    my @target_indexes = grep { $lines[$_] =~ /^\s+- --target=\Q$target\E\s*$/ } 0 .. $#lines;
    die "$path: target argument is not unique\n" unless @target_indexes == 1;
    my $target_index = $target_indexes[0];
    my ($start, $labels);
    for (my $i = $target_index; $i >= 0; --$i) {
        if ($lines[$i] eq "  extra_refs:\n") { $start = $i; last; }
    }
    for (my $i = $start + 1; $i < $target_index; ++$i) {
        if ($lines[$i] eq "  labels:\n") { $labels = $i; last; }
    }
    die "$path: could not locate generated extra_refs block\n"
      unless defined $start && defined $labels;
    my @refs = @lines[$start .. $labels - 1];
    my $refs = join "", @refs;
    die "$path: expected one target extra_ref\n"
      unless $refs =~ /^  extra_refs:\n  - base_ref: \S+\n/m
      && $refs !~ /workdir:|repo: release/;
    push @refs, "    workdir: true\n";
    push @refs,
      "  - base_ref: main\n",
      "    org: openshift\n",
      "    path_alias: github.com/openshift/release\n",
      "    repo: release\n",
      "    sparse_checkout_files:\n",
      map { "    - $_\n" } @source_files;
    splice @lines, $start, $labels - $start, @refs;
    write_file($path, join "", @lines);
    ++$changed;
}
print "release source refs ready; updated $changed generated job file(s)\n";
