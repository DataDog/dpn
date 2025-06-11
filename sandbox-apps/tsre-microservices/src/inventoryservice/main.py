import os
import sys
import time
import random
from flask import Flask, jsonify, request
from logger import getJSONLogger
from collections import defaultdict

app = Flask(__name__)

# Configure logging using the JSON logger
logger = getJSONLogger('inventoryservice')

# Simulate inventory data
inventory_data = {}

# Cache for product history - this will grow unbounded
product_history_cache = defaultdict(list)
# Cache for analytics data - also grows unbounded
analytics_cache = defaultdict(lambda: {'views': 0, 'updates': 0, 'history': []})

def process_inventory():
    """Process inventory data"""
    while True:
        try:
            # Simulate normal inventory processing
            start_time = time.time()
            products_processed = 0
            
            for i in range(50):  # Reduced from 200 to 50 products per iteration
                # Normal inventory processing
                product_id = f"PROD-{random.randint(1000, 9999)}"
                stock = random.randint(0, 100)
                reserved = random.randint(0, 50)
                
                # Update inventory
                inventory_data[product_id] = {
                    'stock': stock,
                    'reserved': reserved
                }
                
                # Memory leak: Store complete history of every change with larger data
                # This is a common mistake in real applications
                product_history_cache[product_id].append({
                    'timestamp': time.time(),
                    'stock': stock,
                    'reserved': reserved,
                    'change_id': f"CHG-{random.randint(10000, 99999)}",
                    'metadata': {
                        'source': random.choice(['manual', 'auto', 'sync']),
                        'user': f"user_{random.randint(1, 100)}",
                        'reason': random.choice(['restock', 'sale', 'adjustment', 'return']),
                        'details': {
                            'location': f"warehouse_{random.randint(1, 5)}",
                            'batch': f"batch_{random.randint(1000, 9999)}",
                            'notes': 'x' * 400,  # Increased from 200 to 400
                            'additional_data': {
                                'items': [{'id': j, 'value': 'x' * 100} for j in range(30)]  # Increased from 20 to 30 items
                            }
                        }
                    }
                })
                
                # Memory leak: Store analytics data without cleanup
                analytics_cache[product_id]['views'] += random.randint(1, 10)
                analytics_cache[product_id]['updates'] += 1
                analytics_cache[product_id]['history'].append({
                    'timestamp': time.time(),
                    'action': random.choice(['view', 'update', 'check']),
                    'user_agent': f"browser_{random.randint(1, 5)}",
                    'session_id': f"sess_{random.randint(10000, 99999)}",
                    'response_time': random.uniform(0.1, 2.0),
                    'additional_metrics': {
                        'cpu_usage': random.uniform(0, 100),
                        'memory_usage': random.uniform(0, 100),
                        'network_latency': random.uniform(0, 1000),
                        'detailed_trace': 'x' * 200  # Increased from 100 to 200
                    }
                })
                
                products_processed += 1
                
                # Log low stock warnings
                if stock < 10:
                    logger.warning(f"Low stock alert for product {product_id}", extra={
                        'product_id': product_id,
                        'current_stock': stock,
                        'reserved': reserved
                    })
                
                # Log memory usage every 10 iterations
                if i % 10 == 0:
                    total_history_entries = sum(len(history) for history in product_history_cache.values())
                    total_analytics_entries = sum(len(data['history']) for data in analytics_cache.values())
                    logger.info(f"Memory usage metrics", extra={
                        'iteration': i,
                        'products_processed': products_processed,
                        'total_products': len(inventory_data),
                        'total_history_entries': total_history_entries,
                        'total_analytics_entries': total_analytics_entries,
                        'cache_size': len(product_history_cache) + len(analytics_cache)
                    })
            
            processing_time = time.time() - start_time
            logger.info(f"Inventory processing complete", extra={
                'products_processed': products_processed,
                'processing_time_seconds': round(processing_time, 2),
                'total_products': len(inventory_data),
                'total_history_entries': sum(len(history) for history in product_history_cache.values()),
                'total_analytics_entries': sum(len(data['history']) for data in analytics_cache.values())
            })
            
            time.sleep(2)  # Increased from 1 to 2 seconds
            
        except Exception as e:
            logger.error(f"Unexpected error in inventory processing", extra={
                'error': str(e),
                'error_type': type(e).__name__
            })
            sys.exit(1)

@app.route('/health')
def health_check():
    logger.info("Health check requested")
    return jsonify({"status": "healthy"})

@app.route('/inventory/<product_id>')
def get_inventory(product_id):
    logger.info(f"Inventory lookup requested", extra={
        'product_id': product_id,
        'client_ip': request.remote_addr
    })
    
    # Memory leak: Track every request in analytics without cleanup
    analytics_cache[product_id]['views'] += 1
    analytics_cache[product_id]['history'].append({
        'timestamp': time.time(),
        'action': 'view',
        'user_agent': request.headers.get('User-Agent', 'unknown'),
        'session_id': request.headers.get('X-Session-ID', 'unknown'),
        'response_time': random.uniform(0.1, 2.0),
        'additional_metrics': {
            'cpu_usage': random.uniform(0, 100),
            'memory_usage': random.uniform(0, 100),
            'network_latency': random.uniform(0, 1000),
            'detailed_trace': 'x' * 100  # Reduced from 500 to 100
        }
    })
    
    if product_id in inventory_data:
        logger.info(f"Product found", extra={
            'product_id': product_id,
            'stock': inventory_data[product_id]['stock'],
            'reserved': inventory_data[product_id]['reserved']
        })
        return jsonify(inventory_data[product_id])
    
    logger.warning(f"Product not found", extra={
        'product_id': product_id,
        'client_ip': request.remote_addr
    })
    return jsonify({
        "product_id": product_id,
        "quantity": 0,
        "status": "not_found"
    })

if __name__ == '__main__':
    try:
        logger.info("Starting inventory service")
        process_inventory()
    except Exception as e:
        logger.error(f"Service failed to start", extra={
            'error': str(e),
            'error_type': type(e).__name__
        })
        sys.exit(1) 