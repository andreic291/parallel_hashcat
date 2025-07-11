#!/bin/bash

# Container management script for hashcat performance testing

CONTAINERS=("hashcat-single" "hashcat-parallel-1" "hashcat-parallel-2")

show_usage() {
    echo "Usage: $0 {start|stop|restart|status|logs|shell}"
    echo ""
    echo "Commands:"
    echo "  start    - Start all hashcat containers"
    echo "  stop     - Stop all hashcat containers"
    echo "  restart  - Restart all hashcat containers" 
    echo "  status   - Show container status"
    echo "  logs     - Show logs from all containers"
    echo "  shell    - Open shell in specified container"
    echo ""
    echo "Examples:"
    echo "  $0 start                           # Start all containers"
    echo "  $0 shell hashcat-single           # Open shell in single container"
    echo "  $0 shell                          # Open shell in hashcat-single (default)"
}

start_containers() {
    echo "Starting hashcat containers..."
    docker-compose up -d
    
    echo "Waiting for containers to be ready..."
    sleep 3
    
    # Verify containers are running
    for container in "${CONTAINERS[@]}"; do
        if docker exec "$container" echo "Container ready" >/dev/null 2>&1; then
            echo "✓ $container is ready"
        else
            echo "✗ $container failed to start"
        fi
    done
}

stop_containers() {
    echo "Stopping hashcat containers..."
    
    # First, stop any running hashcat processes
    for container in "${CONTAINERS[@]}"; do
        echo "Stopping hashcat processes in $container..."
        docker exec "$container" pkill -f hashcat 2>/dev/null || true
    done
    
    # Then stop containers
    docker-compose stop
    echo "All containers stopped."
}

restart_containers() {
    echo "Restarting hashcat containers..."
    stop_containers
    sleep 2
    start_containers
}

show_status() {
    echo "Container Status:"
    echo "=================="
    
    for container in "${CONTAINERS[@]}"; do
        if docker ps -q -f name="$container" >/dev/null 2>&1; then
            STATUS=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
            UPTIME=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null | xargs date -d)
            echo "✓ $container: $STATUS (started: $UPTIME)"
            
            # Check if hashcat is running
            if docker exec "$container" pgrep -f hashcat >/dev/null 2>&1; then
                echo "  → hashcat process: RUNNING"
            else
                echo "  → hashcat process: IDLE"
            fi
        else
            echo "✗ $container: NOT RUNNING"
        fi
        echo ""
    done
    
    # Show resource usage
    echo "Resource Usage:"
    echo "==============="
    docker stats --no-stream "${CONTAINERS[@]}" 2>/dev/null || echo "No containers running"
}

show_logs() {
    echo "Recent logs from all containers:"
    echo "================================"
    docker-compose logs --tail=20 "${CONTAINERS[@]}"
}

open_shell() {
    local container=${1:-hashcat-single}
    
    if docker ps -q -f name="$container" >/dev/null 2>&1; then
        echo "Opening shell in $container..."
        echo "Type 'exit' to return to host shell"
        docker exec -it "$container" /bin/bash
    else
        echo "Error: Container $container is not running"
        echo "Available containers: ${CONTAINERS[*]}"
    fi
}

# Main script logic
case "${1:-}" in
    start)
        start_containers
        ;;
    stop)
        stop_containers
        ;;
    restart)
        restart_containers
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    shell)
        open_shell "$2"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac 