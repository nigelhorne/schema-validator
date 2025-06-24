package Schema::Validator;
use strict;
use warnings;
use JSON::MaybeXS qw(decode_json encode_json);
use LWP::UserAgent;
use Encode qw(decode);
use base 'Exporter';                # Use Exporter as the base class
our @EXPORT_OK = qw(is_valid_datetime load_dynamic_vocabulary);

our $VERSION = '0.01';

# Validates that a string is in YYYY-MM-DD or YYYY-MM-DDTHH:MM(:SS)? format.
sub is_valid_datetime {
    my $val = shift;
    return $val =~ /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?$/;
}

# Loads the dynamic Schema.org vocabulary from Schema.org and returns a hash mapping class labels to their definitions.
sub load_dynamic_vocabulary {
    my $url = 'https://schema.org/version/latest/schemaorg-current-https.jsonld';
    my $ua = LWP::UserAgent->new( timeout => 30 );
    my $res = $ua->get($url);
    unless ($res->is_success) {
        warn "Failed to fetch dynamic vocabulary from $url: " . $res->status_line;
        return ();
    }
    my $content = $res->decoded_content;
    my $data = eval { decode_json($content) };
    if ($@) {
        warn "Failed to parse dynamic vocabulary JSON: $@";
        return ();
    }
    my %vocab;
    if (exists $data->{'@graph'} && ref($data->{'@graph'}) eq 'ARRAY') {
        for my $item (@{ $data->{'@graph'} }) {
            if (exists $item->{'@type'}) {
                my $item_type = $item->{'@type'};
                my $is_class = 0;
                if (ref($item_type) eq 'ARRAY') {
                    $is_class = grep { $_ eq 'rdfs:Class' } @$item_type;
                } else {
                    $is_class = ($item_type eq 'rdfs:Class');
                }
                if ($is_class) {
                    my $label = $item->{'rdfs:label'} // $item->{'http://www.w3.org/2000/01/rdf-schema#label'};
                    next unless $label;
                    $label = ref($label) eq 'ARRAY' ? $label->[0] : $label;
                    $vocab{$label} = $item;
                }
            }
        }
    } else {
        warn "No '\@graph' key found in the vocabulary JSON.";
    }
    return %vocab;
}

1;
