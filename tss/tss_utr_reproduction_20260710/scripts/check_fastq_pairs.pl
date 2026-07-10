#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use IO::Uncompress::Gunzip qw($GunzipError);

my ($sample, $r1_path, $r2_path);

GetOptions(
    'sample=s' => \$sample,
    'r1=s'     => \$r1_path,
    'r2=s'     => \$r2_path,
) or die "usage: $0 --sample ID --r1 R1.fastq.gz --r2 R2.fastq.gz\n";

for my $argument ([sample => $sample], [r1 => $r1_path], [r2 => $r2_path]) {
    die "missing --$argument->[0]\n" if !defined $argument->[1] || $argument->[1] eq q{};
}

my $r1_fh = IO::Uncompress::Gunzip->new($r1_path, MultiStream => 1)
    or die "sample $sample: cannot open R1 gzip $r1_path: $GunzipError\n";
my $r2_fh = IO::Uncompress::Gunzip->new($r2_path, MultiStream => 1)
    or die "sample $sample: cannot open R2 gzip $r2_path: $GunzipError\n";

my ($pairs, $r1_min, $r1_max, $r2_min, $r2_max) = (0, undef, undef, undef, undef);

while (1) {
    my $record_number = $pairs + 1;
    my $r1 = read_record($r1_fh, 'R1', $sample, $record_number);
    my $r2 = read_record($r2_fh, 'R2', $sample, $record_number);

    last if !defined $r1 && !defined $r2;
    if (!defined $r1 || !defined $r2) {
        die "sample $sample record $record_number: R1/R2 record counts differ\n";
    }

    my $r1_name = normalized_name($r1->{header});
    my $r2_name = normalized_name($r2->{header});
    if ($r1_name ne $r2_name) {
        die "sample $sample record $record_number: normalized read names differ "
            . "($r1_name != $r2_name)\n";
    }

    my $r1_length = length $r1->{sequence};
    my $r2_length = length $r2->{sequence};
    $r1_min = !defined $r1_min || $r1_length < $r1_min ? $r1_length : $r1_min;
    $r1_max = !defined $r1_max || $r1_length > $r1_max ? $r1_length : $r1_max;
    $r2_min = !defined $r2_min || $r2_length < $r2_min ? $r2_length : $r2_min;
    $r2_max = !defined $r2_max || $r2_length > $r2_max ? $r2_length : $r2_max;
    $pairs++;
}

die "sample $sample: FASTQ pair contains no records\n" if $pairs == 0;

printf "%s\t%d\t%d\t%d\t%d\t%d\n",
    $sample, $pairs, $r1_min, $r1_max, $r2_min, $r2_max;

sub read_record {
    my ($fh, $mate, $sample_id, $record_number) = @_;
    my $header = <$fh>;
    return if !defined $header;

    my $sequence = <$fh>;
    my $plus = <$fh>;
    my $quality = <$fh>;
    if (!defined $sequence || !defined $plus || !defined $quality) {
        die "sample $sample_id record $record_number: incomplete four-line $mate FASTQ record\n";
    }

    chomp($header, $sequence, $plus, $quality);
    $header =~ s/\r\z//;
    $sequence =~ s/\r\z//;
    $plus =~ s/\r\z//;
    $quality =~ s/\r\z//;

    die "sample $sample_id record $record_number: $mate header does not start with \@\n"
        if $header !~ /^\@\S+/;
    die "sample $sample_id record $record_number: $mate separator does not start with +\n"
        if $plus !~ /^\+/;
    die "sample $sample_id record $record_number: $mate sequence is empty\n"
        if $sequence eq q{};
    if (length($sequence) != length($quality)) {
        die "sample $sample_id record $record_number: $mate sequence/quality lengths differ\n";
    }

    return {
        header   => $header,
        sequence => $sequence,
    };
}

sub normalized_name {
    my ($header) = @_;
    $header =~ s/^\@//;
    $header =~ s/\s.*\z//;
    $header =~ s{/([12])\z}{};
    return $header;
}
