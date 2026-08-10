import json
import subprocess
import sys
import urllib.request
import urllib.error
import time
from datetime import datetime

# --- Configuration ---
VIN = "VIN123456789"
DEVICE_NAME = "board-01111111"
SSID = "MyWifi"
SCRIPT_TO_START = "start_flash.py"
BASE_URL = "http://10.88.145.27:5000"
POLL_INTERVAL = 5  # Seconds between checks

def register_device_connection():
    """
    Step 1: Notifies the server that the device is online.
    Returns True only if the server returns a successful response.
    """
    url = f"{BASE_URL}/insert_wifi_connection"
    payload = {
        "ssid": SSID,
        "device_name": DEVICE_NAME,
        "status": "connected",
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "vin": VIN,
        "startflashing": False
    }

    print(f"--- Attempting Registration: {DEVICE_NAME} ---")
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            if response.status == 200 or response.status == 201:
                print(f"Registration Successful (Status: {response.status})")
                print(f"Server Response: {response.read().decode('utf-8')}\n")
                return True
            else:
                print(f"Registration Refused (Status: {response.status})")
                return False
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        print(f"CRITICAL: Registration failed (Network/Server Error: {e})")
        return False
    except Exception as e:
        print(f"CRITICAL: An unexpected error occurred: {e}")
        return False

def start_monitoring_loop():
    """
    Step 2: Polls the server continuously until 'startflashing' becomes true.
    """
    url = f"{BASE_URL}/get_startflashing/{VIN}"
    print(f"--- Monitoring for Start Signal (VIN: {VIN}) ---")

    while True:
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                body = response.read().decode("utf-8")
                data = json.loads(body)

                startflashing = bool(data.get("startflashing", False))
                current_time = datetime.now().strftime("%H:%M:%S")

                if startflashing:
                    print(f"[{current_time}] SIGNAL RECEIVED! Starting {SCRIPT_TO_START}...")
                    subprocess.Popen([sys.executable, SCRIPT_TO_START])
                    break  # Exit loop once the flash is triggered
                else:
                    print(f"[{current_time}] Status: False. Waiting {POLL_INTERVAL}s...")

        except Exception as e:
            # We keep looping here as the registration was already successful once
            print(f"Polling error: {e}. Retrying...")
        
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    # 1. Attempt registration
    registration_success = register_device_connection()
    
    # 2. Only proceed if registration was successful
    if registration_success:
        start_monitoring_loop()
    else:
        print("Exiting script because registration could not be completed.")
        sys.exit(1)