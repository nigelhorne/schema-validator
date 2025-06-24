#!/usr/bin/env perl
use strict;
use warnings;
use Mojo::DOM;
use JSON::MaybeXS qw(decode_json encode_json);
use Encode qw(decode);
use Getopt::Long;

# Command-line options
my $file;
my $github_mode = 0;
GetOptions(
    "file=s"   => \$file,
    "github"   => \$github_mode,
) or die "Usage: $0 --file input.html [--github]\n";
die "Usage: $0 --file input.html [--github]\n" unless $file;

# Global array to collect SARIF results during validation.
my @sarif_results;

# Define a minimal local schema for our purposes.
# In our sample, a MusicEvent must have a name, startdate, and a location object of type PostalAddress.
my %schema = (
    MusicEvent => {
        required => [qw(name startdate location)],
        nested   => { location => 'PostalAddress' },
    },
    PostalAddress => {
        required => [qw(addressCountry addressLocality)],
    },
);

# Read the input file in raw mode and decode it from Windows-1252.
open my $fh, '<:raw', $file or die "Cannot open file '$file': $!";
local $/;
my $raw_content = <$fh>;
close $fh;
my $html = decode('Windows-1252', $raw_content);

# Parse the HTML using Mojo::DOM which gracefully tolerates malformed markup.
my $dom = Mojo::DOM->new($html);

# Find all <script type="application/ld+json"> tags.
my $scripts = $dom->find('script[type="application/ld+json"]');

foreach my $script ($scripts->each) {
    my $json_text = $script->all_text;
    $json_text =~ s/^\s+|\s+$//g;
    next unless length $json_text;
    
    my $data = eval { decode_json($json_text) };
    if ($@ || !$data) {
         warn "Invalid JSON: $@\n";
         next;
    }
    
    unless ($github_mode) {
         print "Found Schema.org block:\n";
    }
    # Process the JSON-LD block (it may be a HASH or an ARRAY)
    if (ref $data eq 'ARRAY') {
         foreach my $entity (@$data) {
             validate_entity($entity, 0, '');
         }
    }
    else {
         validate_entity($data, 0, '');
    }
}

# If running in GitHub mode then output the results in a SARIF file.
if ($github_mode) {
    my $sarif_output = {
        version => "2.1.0",
        runs    => [
            {
                tool => {
                    driver => {
                        name             => "Schema.org Validator",
                        informationUri => "https://schema.org",
                        version          => "1.0",
                        rules            => [
                            { id => "SCHEMA000", name => "Missing \@type" },
                            { id => "SCHEMA001", name => "Missing required property" },
                            { id => "SCHEMA002", name => "Unknown type" },
                        ],
                    },
                },
                results => \@sarif_results,
            },
        ],
    };
    # Write out the SARIF JSON; GitHub Actions can upload this as an artifact.
    open my $sfh, '>', "schema_validation.sarif" or die "Can't open output SARIF file: $!";
    print $sfh encode_json($sarif_output);
    close $sfh;
    print "SARIF output written to schema_validation.sarif\n";
}

#
# Recursive subroutine to validate a JSON-LD entity.
#
sub validate_entity {
    my ($entity, $depth, $currentPath) = @_;
    $depth         //= 0;
    $currentPath   = defined $currentPath ? $currentPath : '';
    my $indent = ' ' x ($depth * 2);

    # Every valid block should at least have an '@type'
    unless (ref $entity eq 'HASH' && exists $entity->{'@type'}) {
        my $msg = "Missing or invalid \@type at " . ($currentPath || 'root');
        if ($github_mode) {
            push @sarif_results, {
                ruleId    => "SCHEMA000",
                level     => "error",
                message   => { text => $msg },
                locations => [{
                    physicalLocation => {
                        artifactLocation => { uri => $file }
                    }
                }],
            };
        } else {
            print "${indent}✗ Missing or invalid \@type at " . ($currentPath || 'root') . "\n";
        }
        return;
    }

    my $type = $entity->{'@type'};
    unless ($github_mode) {
        print "${indent}• Type: $type at " . ($currentPath || 'root') . "\n";
    }

    # If our known schema contains rules for this type, validate them.
    if (exists $schema{$type}) {
        my $rules = $schema{$type};
        # Check required properties.
        for my $req (@{ $rules->{required} }) {
            unless (exists $entity->{$req}) {
                my $msg = "Missing required property '$req' for type '$type' at " . ($currentPath || 'root');
                if ($github_mode) {
                    push @sarif_results, {
                        ruleId    => "SCHEMA001",
                        level     => "error",
                        message   => { text => $msg },
                        locations => [{
                            physicalLocation => {
                                artifactLocation => { uri => $file }
                            }
                        }],
                    };
                } else {
                    print "${indent}✗ Missing required property '$req' for type '$type' at " . ($currentPath || 'root') . "\n";
                }
            }
        }
        # Recurse to validate nested objects if any.
        if (my $nested = $rules->{nested}) {
            for my $prop (keys %$nested) {
                if (exists $entity->{$prop}) {
                    my $child = $entity->{$prop};
                    my $childPath = $currentPath ? "$currentPath->$prop" : $prop;
                    if (ref $child eq 'ARRAY') {
                        unless ($github_mode) {
                            print "${indent}-> $prop (array)\n";
                        }
                        for my $i (0 .. $#$child) {
                            my $itemPath = $childPath . "[$i]";
                            validate_entity($child->[$i], $depth + 1, $itemPath);
                        }
                    }
                    elsif (ref $child eq 'HASH') {
                        unless ($github_mode) {
                            print "${indent}-> $prop (object)\n";
                        }
                        validate_entity($child, $depth + 1, $childPath);
                    }
                }
            }
        }
        unless ($github_mode) {
            print "${indent}✓ $type passes basic validation at " . ($currentPath || 'root') . "\n\n";
        }
    }
    else {
        # Unknown types trigger a warning.
        my $msg = "Unknown type '$type' at " . ($currentPath || 'root') . ". Skipping detailed rules check.";
        if ($github_mode) {
            push @sarif_results, {
                ruleId    => "SCHEMA002",
                level     => "warning",
                message   => { text => $msg },
                locations => [{
                    physicalLocation => {
                        artifactLocation => { uri => $file }
                    }
                }],
            };
        } else {
            print "${indent}⚠ Unknown type '$type' at " . ($currentPath || 'root') . ". Skipping detailed rules check.\n";
        }
    }
}
