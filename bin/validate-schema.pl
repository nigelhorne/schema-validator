#!/usr/bin/env perl
use strict;
use warnings;
use Mojo::DOM;
use JSON::MaybeXS qw(decode_json encode_json);
use Encode qw(decode);
use Getopt::Long;
use Scalar::Util 'looks_like_number';

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

#-----------------------------------------------------------------
# Helper: push_validation
# Centralizes error/warning message production.
sub push_validation {
    my ($rule, $message, $location) = @_;
    if ($github_mode) {
        push @sarif_results, {
            ruleId    => $rule,
            level     => "error",
            message   => { text => $message },
            locations => [{
                physicalLocation => {
                    artifactLocation => { uri => $file }
                }
            }],
        };
    } else {
        print "✗ [$rule] $message at $location\n";
    }
}

#-----------------------------------------------------------------
# Helper: is_valid_datetime
# Validates that the given value matches YYYY-MM-DD or YYYY-MM-DDTHH:MM(:SS)?
sub is_valid_datetime {
    my $val = shift;
    return $val =~ /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?$/;
}

#-----------------------------------------------------------------
# Cross-field validation for MusicEvent performer.
# Ensures that if a MusicEvent defines a 'performer', its @type must be either PerformingGroup or Person.
sub validate_performer {
    my ($entity, $currentPath) = @_;
    if (exists $entity->{performer}) {
        my $perf = $entity->{performer};
        my @perfs = (ref($perf) eq 'ARRAY') ? @$perf : ($perf);
        foreach my $p (@perfs) {
            if (ref $p eq 'HASH') {
                unless ($p->{'@type'} && ($p->{'@type'} =~ /^(PerformingGroup|Person)$/)) {
                    push_validation("SCHEMA005", "Performer must be of type PerformingGroup or Person", "$currentPath->performer");
                }
            } else {
                push_validation("SCHEMA005", "Performer invalid format: expected JSON object", "$currentPath->performer");
            }
        }
    }
}

#-----------------------------------------------------------------
# Expanded schema definition.
# Each type defines:
#  - required: required property names.
#  - nested: properties whose values are nested objects to validate (using a specified type).
#  - property_validations: custom validations (e.g. checking formats such as dates).
#  - enum: for properties with specific allowed values.
my %schema = (
    MusicEvent => {
        required => [qw(name startdate location)],
        # "location" is a nested PostalAddress.
        nested   => { location => 'PostalAddress' },
        property_validations => {
            startdate => \&is_valid_datetime,
        },
    },
    PostalAddress => {
        required => [qw(addressCountry addressLocality)],
        # Enumerated allowed values (example: you can extend this list per your requirements).
        enum => {
            addressCountry => [qw(United_States Canada United_Kingdom)],
        },
    },
    PerformingGroup => {
        required => [qw(name)],
    },
    Person => {
        required => [qw(name)],
    },
);

#-----------------------------------------------------------------
# Read the input file in raw mode and decode from Windows-1252.
open my $fh, '<:raw', $file or die "Cannot open file '$file': $!";
local $/;
my $raw_content = <$fh>;
close $fh;
my $html = decode('Windows-1252', $raw_content);

#-----------------------------------------------------------------
# Parse HTML using Mojo::DOM (tolerates malformed markup).
my $dom = Mojo::DOM->new($html);
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
    # Process the block (array or single object).
    if (ref $data eq 'ARRAY') {
        foreach my $entity (@$data) {
            validate_entity($entity, 0, '');
        }
    }
    else {
        validate_entity($data, 0, '');
    }
}

#-----------------------------------------------------------------
# If in GitHub mode, output SARIF report.
if ($github_mode) {
    my $sarif_output = {
        version => "2.1.0",
        runs    => [
            {
                tool => {
                    driver => {
                        name             => "Schema.org Validator",
                        informationUri   => "https://schema.org",
                        version          => "1.1",
                        rules            => [
                            { id => "SCHEMA000", name => 'Missing @type' },
                            { id => "SCHEMA001", name => "Missing required property" },
                            { id => "SCHEMA003", name => "Invalid property format" },
                            { id => "SCHEMA004", name => "Unexpected enumerated value" },
                            { id => "SCHEMA005", name => "Invalid performer type" },
                            { id => "SCHEMA002", name => "Unknown type" },
                        ],
                    },
                },
                results => \@sarif_results,
            },
        ],
    };
    open my $sfh, '>', "schema_validation.sarif" or die "Can't open output SARIF file: $!";
    print $sfh encode_json($sarif_output);
    close $sfh;
    print "SARIF output written to schema_validation.sarif\n";
}

#-----------------------------------------------------------------
# Recursive function: validate_entity
# Validates a JSON-LD block against our expanded schema.
sub validate_entity {
    my ($entity, $depth, $currentPath) = @_;
    $depth         //= 0;
    $currentPath   = defined $currentPath ? $currentPath : '';
    my $indent = ' ' x ($depth * 2);
    
    unless (ref $entity eq 'HASH' && exists $entity->{'@type'}) {
        push_validation("SCHEMA000", "Missing or invalid \@type", ($currentPath || 'root'));
        return;
    }
    
    my $type = $entity->{'@type'};
    unless ($github_mode) {
        print "${indent}• Type: $type at " . ($currentPath || 'root') . "\n";
    }
    
    if (exists $schema{$type}) {
        my $rules = $schema{$type};
        # Check for required properties.
        for my $req (@{ $rules->{required} }) {
            unless (exists $entity->{$req}) {
                push_validation("SCHEMA001", "Missing required property '$req' for type '$type'", ($currentPath || 'root'));
            }
        }
        
        # Check enumerated values.
        if ($rules->{enum}) {
            for my $prop (keys %{ $rules->{enum} }) {
                if (exists $entity->{$prop}) {
                    my @allowed = @{ $rules->{enum}->{$prop} };
                    unless (grep { $_ eq $entity->{$prop} } @allowed) {
                        push_validation("SCHEMA004", "Unexpected value '$entity->{$prop}' for property '$prop'", ($currentPath || 'root'));
                    }
                }
            }
        }
        
        # Custom property validations.
        if ($rules->{property_validations}) {
            for my $prop (keys %{ $rules->{property_validations} }) {
                if (exists $entity->{$prop}) {
                    my $validator = $rules->{property_validations}->{$prop};
                    unless ($validator->($entity->{$prop})) {
                        push_validation("SCHEMA003", "Invalid format for property '$prop'", ($currentPath || 'root'));
                    }
                }
            }
        }
        
        # Validate nested objects.
        if ($rules->{nested}) {
            for my $prop (keys %{ $rules->{nested} }) {
                if (exists $entity->{$prop}) {
                    my $child = $entity->{$prop};
                    my $childPath = $currentPath ? "$currentPath->$prop" : $prop;
                    if (ref $child eq 'ARRAY') {
                        for my $i (0 .. $#$child) {
                            my $itemPath = $childPath . "[$i]";
                            validate_entity($child->[$i], $depth + 1, $itemPath);
                        }
                    } elsif (ref $child eq 'HASH') {
                        validate_entity($child, $depth + 1, $childPath);
                    }
                }
            }
        }
        
        # Cross-field check: validate MusicEvent performer.
        if ($type eq 'MusicEvent') {
            validate_performer($entity, $currentPath || 'root');
        }
        
        unless ($github_mode) {
            print "${indent}✓ $type passes basic validation at " . ($currentPath || 'root') . "\n\n";
        }
    }
    else {
        push_validation("SCHEMA002", "Unknown type '$type'. Skipping detailed rules check.", ($currentPath || 'root'));
    }
}
