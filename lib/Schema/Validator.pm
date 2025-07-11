package Schema::Validator;
use strict;
use warnings;
use JSON::MaybeXS qw(decode_json encode_json);
use LWP::UserAgent;
use Encode qw(decode);
use base 'Exporter';				# Use Exporter as the base class
our @EXPORT_OK = qw(is_valid_datetime load_dynamic_vocabulary);

our $VERSION = '0.01';

our %dynamic_properties;	# Global variable to store property definitions
our %dynamic_schema;	# Global variable to store class definitions

# Validates that a string is in YYYY-MM-DD or YYYY-MM-DDTHH:MM(:SS)? format.
sub is_valid_datetime {
	my $val = shift;
	return $val =~ /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?$/;
}

# Loads the dynamic Schema.org vocabulary from Schema.org and returns a hash mapping class labels to their definitions.
sub load_dynamic_vocabulary {
	my $cache_file	 = "schemaorg_dynamic_vocabulary.jsonld";
	my $cache_duration = 86400;	# Cache expires in 1 day (86400 seconds)
	my $content;
	my $use_cache = 0;

	if (-e $cache_file) {
		my $mtime = (stat($cache_file))[9];
		if ( time - $mtime < $cache_duration ) {
			$use_cache = 1;
		}
	}

	if ($use_cache) {
		# Read from the cache file
		open my $cfh, '<', $cache_file or warn "Could not open cache file $cache_file: $!";
		{
			local $/;	# Slurp mode
			$content = <$cfh>;
		}
		close $cfh;
	} else {
		# Download the vocabulary from Schema.org
		my $url = 'https://schema.org/version/latest/schemaorg-current-https.jsonld';
		my $ua = LWP::UserAgent->new( timeout => 30 );
		my $res = $ua->get($url);
		unless ($res->is_success) {
			warn "Failed to fetch dynamic vocabulary from $url: " . $res->status_line;
			return ();
		}
		$content = $res->decoded_content;
		# Write the downloaded content to the cache file.
		open my $cfh, '>', $cache_file or warn "Could not write to cache file $cache_file: $!";
		print $cfh $content;
		close $cfh;
	}

	my $data = eval { decode_json($content) };
	if ($@) {
		warn "Failed to parse dynamic vocabulary JSON: $@";
		return ();
	}

	my %class_vocab;
	my %prop_vocab;

	if (exists $data->{'@graph'} && ref($data->{'@graph'}) eq 'ARRAY') {
		for my $item (@{ $data->{'@graph'} }) {
			next unless exists $item->{'@type'};
			my $item_type = $item->{'@type'};

			# Check for class definitions
			my $is_class = 0;
			if (ref($item_type) eq 'ARRAY') {
				$is_class = grep { $_ eq 'rdfs:Class' } @$item_type;
			} else {
				$is_class = ($item_type eq 'rdfs:Class');
			}
			if ($is_class) {
				my $label = $item->{'rdfs:label'} // $item->{'http://www.w3.org/2000/01/rdf-schema#label'};
				next unless $label;
				$label = (ref($label) eq 'ARRAY') ? $label->[0] : $label;
				$class_vocab{$label} = $item;
			}

			# Check for property definitions (e.g. items with @type 'rdf:Property')
			my $is_prop = 0;
			if (ref($item_type) eq 'ARRAY') {
				$is_prop = grep { $_ eq 'rdf:Property' } @$item_type;
			} else {
				$is_prop = ($item_type eq 'rdf:Property');
			}
			if ($is_prop) {
				my $label = $item->{'rdfs:label'} // $item->{'http://www.w3.org/2000/01/rdf-schema#label'};
				next unless $label;
				$label = (ref($label) eq 'ARRAY') ? $label->[0] : $label;
				$prop_vocab{$label} = $item;
			}
		}
	} else {
		warn "No '\@graph' key found in the vocabulary JSON.";
	}

	# Assign the populated hashes to the global variables.
	%dynamic_schema	 = %class_vocab;
	%dynamic_properties = %prop_vocab;

	warn 'Dynamic vocabulary loaded: ', scalar(keys %dynamic_schema),
		 ' classes and ', scalar(keys %dynamic_properties), ' properties found.';

	return %dynamic_schema;
}


1;
