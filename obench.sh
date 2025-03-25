#!/usr/bin/env bash
# Benchmark using ollama gives rate of tokens per second
# idea taken from https://taoofmac.com/space/blog/2024/01/20/1800

set -e

usage() {
 echo "Usage: $0 [OPTIONS]"
 echo "Options:"
 echo " -h, --help      Display this help message"
 echo " -d, --default   Run a benchmark using some default small models"
 echo " -m, --model     Specify a model to use"
 echo " -c, --count     Number of times to run the benchmark"
 echo " -l, --load      Max Number of models to load (1 default)"
 echo " -p, --parallel  Max Number of parallel requests to a model (1 default)"
 echo " -s, --ctxsize   Context size (2048 default)"
 echo " -q, --qsize     Queue size (512 default)"
 echo " --ollama-bin    Point to ollama executable or command (e.g if using Docker)"
 echo " --markdown      Format output as markdown"
}

# Parse flags passed to program
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --ollama-bin)
            ollama_bin="$2"
            shift
            shift
            ;;
        -d|--default)
            default_flag=true
            shift
            ;;
        --markdown)
            markdown=true
            shift
            ;;
        -m|--model)
            model="$2"
            shift
            shift
            ;;
        -c|--count)
            benchmark="$2"
            shift
            shift
            ;;
        -l|--load)
            load="$2"
            shift
            shift
            ;;
        -p|--parallel)
            parallel="$2"
            shift
            shift
            ;;
        -pc|--pcount)
            pcount="$2"
            shift
            shift
            ;;
        -s|--ctxsize)
            ctxsize="$2"
            shift
            shift
            ;;
        -q|--qsize)
            qsize="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$ollama_bin" ]; then
    ollama_bin="ollama"
fi

base_cmd=$(echo "$ollama_bin" | awk '{print $1}')
if ! command -v "$base_cmd" &> /dev/null; then
    echo "Error: $base_cmd could not be found. Please check the path or install it."
    exit 1
fi

# Original comment about defaults mentions running multiple models that fit
# into memory, but for simplicity and ease of replication I just picked one.
if [ "$default_flag" = true ]; then
    benchmark=3
    model="llama3.2:3b"
fi

if [ -z "$benchmark" ]; then
    echo "How many times to run the serial benchmark?"
    read -r benchmark
fi

if [ -z "$pcount" ]; then
    echo "How many requests to run on the parallel benchmark?"
    read -r pcount
fi

if [ -z "$model" ]; then
    echo "Current models available locally"
    echo ""
    $ollama_bin list
    echo ""
    echo "Enter model you'd like to run (e.g. llama3.2)"
    echo ""
    read -r model
fi

if [ -z "$load" ]; then
    echo "The maximum number of models that can be loaded concurrently provided they fit in available memory."
    echo "The default is 3 * the number of GPUs or 3 for CPU inference."
    echo ""
    read -r load
    if [ -n "$load" ]; then
      export OLLAMA_MAX_LOADED_MODELS=$load
      if [[ "$OSTYPE" == "darwin"* ]]; then
          launchctl setenv OLLAMA_MAX_LOADED_MODELS "$load"
      fi
    fi
fi

if [ -z "$parallel" ]; then
    echo "The maximum number of parallel requests each model will process at the same time."
    echo "(The default will auto-select either 4 or 1 based on available memory.)"
    echo ""
    read -r parallel
    if [ -n "$parallel" ]; then
      export OLLAMA_NUM_PARALLEL=$parallel
      if [[ "$OSTYPE" == "darwin"* ]]; then
          launchctl setenv OLLAMA_NUM_PARALLEL "$parallel"
      fi
    fi
fi

if [ -z "$ctxsize" ]; then
  echo "Context size. Default 2048."
  echo ""
  read -r ctxsize
  if [ -n "$ctxsize" ]; then
    export OLLAMA_CONTEXT_LENGTH=$ctxsize
    if [[ "$OSTYPE" == "darwin"* ]]; then
        launchctl setenv OLLAMA_CONTEXT_LENGTH "$ctxsize"
    fi
  else
    OLLAMA_CONTEXT_LENGTH=2048
  fi
fi

if [ -z "$qsize" ]; then
  echo "The maximum number of requests Ollama will queue when busy before rejecting additional requests."
  echo "The default is 512"
  echo ""
  read -r qsize
  if [ -n "$qsize" ]; then
    export OLLAMA_MAX_QUEUE=$qsize
    if [[ "$OSTYPE" == "darwin"* ]]; then
        launchctl setenv OLLAMA_MAX_QUEUE "$qsize"
    fi
  else
      OLLAMA_MAX_QUEUE=512
  fi
fi


echo -e "Running benchmark $benchmark times using model: $model"
echo ""
echo -e "Ollama Configuration:"
echo "|---------------------------------|"
echo "Max Loaded Models : "  $OLLAMA_MAX_LOADED_MODELS
echo "Max Num Parallel  : "  $OLLAMA_NUM_PARALLEL
echo "Max Request Queue : "  $OLLAMA_MAX_QUEUE
echo "Context Size      : "  $OLLAMA_CONTEXT_LENGTH
echo "|---------------------------------|"

echo ""
echo "Serial Execution:"
echo ""
if [ "$markdown" = true ]; then
    echo "| Run | Eval Rate (Tokens/Second) |"
    echo "|-----|-----------------------------|"
fi

echo ""
start=$(date +%s)
total_eval_rate=0
for run in $(seq 1 "$benchmark"); do
    result=$($ollama_bin run "$model" --verbose "Why is the blue sky blue?" 2>&1 >/dev/null | grep "^eval rate:")
    # With this we could clean up the non-Markdown results a bit more, but leaving it as is for compatibility.
    eval_rate=$(echo "$result" | awk '{print $3}')
    total_eval_rate=$(echo "$total_eval_rate + $eval_rate" | bc -l)
    if [ "$markdown" = true ]; then
        echo "| $run | $eval_rate tokens/s |"
    else
        echo "$result"
    fi
done
end=$(date +%s)

average_eval_rate=$(echo "scale=2; $total_eval_rate / $benchmark" | bc)
if [ "$markdown" = true ]; then
    echo "|**Average Eval Rate**| $average_eval_rate tokens/second |"
else
    echo "Average Eval Rate: $average_eval_rate tokens/second"
fi
echo "Serial Elapsed Time: $(($end-$start)) seconds"

echo ""
echo "Parallel Execution: Using $pcount parallel requests."
echo ""
if [ "$markdown" = true ]; then
    echo "| Run | Eval Rate (Tokens/Second) |"
    echo "|-----|-----------------------------|"
fi
echo ""

#
# https://www.youtube.com/watch?v=MDbdb-W4x4w
#
# run processes storing results and pids in array.
start=$(date +%s)
pids=()
results=()
total_eval_rate=0
for i in $(seq 1 "$pcount"); do
  results[${i}]=$($ollama_bin run "$model" --verbose "Why is the blue sky blue?" 2>&1 >/dev/null | grep "^eval rate:") &
  pids[${i}]=$!
done
for pid in "${pids[@]}"; do
    wait $pid
done
end=$(date +%s)
for i in "${results[@]}"; do
    echo "$i"
    eval_rate=$(echo "$i" | awk '{print $3}')
    total_eval_rate=$(echo "$total_eval_rate + $eval_rate" | bc -l)
done
average_eval_rate=$(echo "scale=2; $total_eval_rate / $pcount" | bc)
if [ "$markdown" = true ]; then
    echo "|**Average Eval Rate**| $average_eval_rate tokens/second |"
else
    echo "Average Eval Rate: $average_eval_rate tokens/second"
fi

echo "Parallel Elapsed Time: $(($end-$start)) seconds"
