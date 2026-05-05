#!/bin/bash
#
# Generic New Relic NerdGraph API query tool
#
# Usage: ./query_newrelic.sh [OPTIONS] <NRQL_QUERY>
#
# Options:
#   -o, --output <file>    Output results to CSV file (default: stdout)
#   -f, --format <format>  Output format: table, csv, json (default: table)
#   -t, --timeout <sec>    Query timeout in seconds (default: 120)
#   -a, --account <id>     New Relic account ID (overrides $NEW_RELIC_ACCOUNT_ID)
#   -q, --query-file <file> Read NRQL query from file
#   -h, --help             Show this help message
#
# Examples:
#   # Simple query to stdout
#   ./query_newrelic.sh "SELECT count(*) FROM Transaction SINCE 1 hour ago"
#
#   # Query with CSV output to file
#   ./query_newrelic.sh -o output.csv -f csv "SELECT * FROM K8sContainerSample SINCE 1 day ago LIMIT 1000"
#
#   # Query with custom timeout
#   ./query_newrelic.sh -t 300 "SELECT * FROM K8sContainerSample SINCE 1 month ago LIMIT MAX"
#
#   # JSON output
#   ./query_newrelic.sh -f json "SELECT average(duration) FROM Transaction FACET appName SINCE 1 day ago"
#
#   # Query from file
#   ./query_newrelic.sh -q query.nrql
#

set -e

# Default values
OUTPUT_FILE=""
FORMAT="table"
TIMEOUT=120
ACCOUNT_ID="${NEW_RELIC_ACCOUNT_ID}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -f|--format)
            FORMAT="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -a|--account)
            ACCOUNT_ID="$2"
            shift 2
            ;;
        -q|--query-file)
            QUERY_FILE="$2"
            shift 2
            ;;
        -h|--help)
            grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //'
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
        *)
            # First non-option argument is the NRQL query
            NRQL_QUERY="$1"
            shift
            break
            ;;
    esac
done

# Read query from file if specified
if [ -n "$QUERY_FILE" ]; then
    if [ ! -f "$QUERY_FILE" ]; then
        echo "ERROR: Query file not found: $QUERY_FILE" >&2
        exit 1
    fi
    NRQL_QUERY=$(cat "$QUERY_FILE")
fi

# Validate inputs
API_KEY="$NEW_RELIC_API_KEY"

if [ -z "$API_KEY" ]; then
    echo "ERROR: NEW_RELIC_API_KEY environment variable not set" >&2
    exit 1
fi

if [ -z "$ACCOUNT_ID" ]; then
    echo "ERROR: NEW_RELIC_ACCOUNT_ID environment variable not set" >&2
    exit 1
fi

if [ -z "$NRQL_QUERY" ]; then
    echo "ERROR: NRQL query is required (provide as argument or via -q/--query-file)" >&2
    echo "Use -h or --help for usage information" >&2
    exit 1
fi

if [[ ! "$FORMAT" =~ ^(table|csv|json)$ ]]; then
    echo "ERROR: Invalid format '$FORMAT'. Must be: table, csv, or json" >&2
    exit 1
fi

# Build the GraphQL query - properly escape the NRQL query for JSON
# Remove newlines and escape quotes and backslashes
ESCAPED_QUERY=$(echo "$NRQL_QUERY" | tr '\n' ' ' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

GRAPHQL_QUERY=$(cat <<EOF
{
  "query": "{ actor { account(id: $ACCOUNT_ID) { nrql(query: \"$ESCAPED_QUERY\", timeout: $TIMEOUT) { results } } } }"
}
EOF
)

echo "Querying New Relic..." >&2
#echo "Query: $NRQL_QUERY" >&2
echo "" >&2

# Make the API call
RESPONSE=$(curl -s --max-time $((TIMEOUT + 10)) -X POST https://api.newrelic.com/graphql \
  -H "Api-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$GRAPHQL_QUERY")

# Check for errors
if echo "$RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    echo "ERROR: New Relic API returned errors:" >&2
    echo "$RESPONSE" | jq '.errors' >&2
    exit 1
fi

# Extract results
if ! echo "$RESPONSE" | jq -e '.data.actor.account.nrql.results' > /dev/null 2>&1; then
    echo "ERROR: Could not retrieve results from New Relic" >&2
    echo "" >&2
    echo "Full response:" >&2
    echo "$RESPONSE" | jq '.' >&2
    exit 1
fi

RESULTS=$(echo "$RESPONSE" | jq '.data.actor.account.nrql.results')

if [ "$RESULTS" = "[]" ] || [ "$RESULTS" = "null" ]; then
    echo "No results found" >&2
    exit 0
fi

# Function to format output
format_output() {
    local format=$1
    local output_file=$2

    case $format in
        json)
            if [ -n "$output_file" ]; then
                echo "$RESULTS" | jq '.' > "$output_file"
                echo "Results written to: $output_file" >&2
            else
                echo "$RESULTS" | jq '.'
            fi
            ;;
        csv)
            # Convert JSON to CSV
            local csv_output
            csv_output=$(jq -r '
                # Get all unique keys from all objects
                (map(keys) | add | unique) as $cols |
                # Output header and data rows
                (($cols | @csv), (.[] | [$cols[] as $k | .[$k] // "" | tostring] | @csv))
            ' <<< "$RESULTS")

            if [ -n "$output_file" ]; then
                echo "$csv_output" > "$output_file"
                echo "Results written to: $output_file" >&2
                echo "Rows: $(echo "$csv_output" | wc -l | xargs)" >&2
            else
                echo "$csv_output"
            fi
            ;;
        table)
            # Format as readable table
            local table_output
            table_output=$(echo "$RESULTS" | jq -r '
                def format_value:
                    if type == "number" then
                        if . == (. | floor) then
                            tostring
                        else
                            (. * 100 | round / 100 | tostring)
                        end
                    elif type == "object" then
                        to_entries | map("\(.key): \(.value)") | join(", ")
                    elif type == "array" then
                        join(", ")
                    elif . == null then
                        "N/A"
                    else
                        tostring
                    end;

                to_entries |
                if length == 0 then
                    empty
                else
                    .[] |
                    if .value | type == "array" then
                        # Multiple results - show each item
                        "Result \(.key + 1):",
                        (.value | to_entries | .[] | "  \(.key): \(.value | format_value)"),
                        ""
                    else
                        # Single result object
                        "Results:",
                        ((.value | type == "object") as $is_obj |
                        if $is_obj then
                            .value | to_entries | .[] | "  \(.key): \(.value | format_value)"
                        else
                            "  Value: \(.value | format_value)"
                        end),
                        ""
                    end
                end
            ')

            # If results is an array, format differently
            if echo "$RESULTS" | jq -e '. | type == "array"' > /dev/null 2>&1; then
                table_output=$(echo "$RESULTS" | jq -r '
                    def format_value:
                        if type == "number" then
                            if . == (. | floor) then
                                tostring
                            else
                                (. * 100 | round / 100 | tostring)
                            end
                        elif type == "object" then
                            to_entries | map("\(.key): \(.value)") | join(", ")
                        elif type == "array" then
                            join(", ")
                        elif . == null then
                            "N/A"
                        else
                            tostring
                        end;

                    .[] |
                    (to_entries |
                    map("  \(.key): \(.value | format_value)") |
                    join("\n")) + "\n"
                ')
            fi

            if [ -n "$output_file" ]; then
                echo "$table_output" > "$output_file"
                echo "Results written to: $output_file" >&2
            else
                echo "$table_output"
            fi
            ;;
    esac
}

# Output results
format_output "$FORMAT" "$OUTPUT_FILE"

# Show summary
RESULT_COUNT=$(echo "$RESULTS" | jq '. | length')
