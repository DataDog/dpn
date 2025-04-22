import json
# install pip install ruamel.yaml
from ruamel.yaml import YAML

def is_price_populated(data, product_name):
    """
    Check if the priceUsd field is populated for a given product name.
    """
    try:
        for product in data.get("products", []):
            if product.get("name") == product_name:
                return "priceUsd" in product and product["priceUsd"] is not None
        return False  # Product not found or no price
    except Exception as e:
        print(f"Error checking price: {e}")
        return False

def set_replay_path(docker_compose_file, service_name, replay_path):
    """
    Set the REPLAY_PATH in the docker-compose.yml file.
    """
    try:
        yaml = YAML()
        yaml.preserve_quotes = True

        # Read the existing docker-compose.yml file
        with open(docker_compose_file, "r") as file:
            docker_compose = yaml.safe_load(file)

        service = docker_compose.get("services", {}).get(service_name)
        if not service:
            print(f"Service '{service_name}' not found in {docker_compose_file}")
            return
        
        # Check if REPLAY_PATH exists, update it; otherwise, add it
        updated = False
        for i, env_var in enumerate(service["environment"]):
            if env_var.startswith("REPLAY_PATH="):
                service["environment"][i] = f"REPLAY_PATH={replay_path}"
                updated = True
                break
        
        if not updated:
            service["environment"].append(f"REPLAY_PATH={replay_path}")

        # Write the updated docker-compose.yml file back
        with open(docker_compose_file, "w") as file:
            yaml.dump(docker_compose, file)

        print(f"Set REPLAY_PATH to {replay_path} in service '{service_name}' of {docker_compose_file}")
    except Exception as e:
        print(f"Error setting REPLAY_PATH: {e}")

def main():
    # Read JSON file
    try:
        with open("../swagbot/src/resources/products.json", "r") as file:
            data = json.load(file)
    except Exception as e:
        print(f"Error reading JSON file: {e}")
        return

    # Check if price is populated
    if is_price_populated(data, "Dog Steel Bottle"):
        print(f"priceUsd is  populated for Dog Steel Bottle!!!")
        set_replay_path("../swagbot/docker-compose.yml", "swagbot", "resources/replay_data_fixed_products")
    else:
        print(f"priceUsd is NOT populated for Dog Steel Bottle - please fix the data!!!")
        set_replay_path("../swagbot/docker-compose.yml", "swagbot", "resources/replay_data")

if __name__ == "__main__":
    main()