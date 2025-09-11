from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time, os

# EMS credentials and config path
url = "https://172.27.28.165.nip.io/ems/login"
username = "root"
password = "root123"
config_dir = "config_files"

# Mapping suffix to tab name
suffix_tab_map = {
    "_amf": "AMF",
    "_smf": "SMF",
    "_upf": "UPF"
}

# Start browser
options = webdriver.ChromeOptions()
options.add_argument("--headless")  # Remove this line to see browser
driver = webdriver.Chrome(options=options)

# Login
driver.get(url)

# Wait for login fields
WebDriverWait(driver, 10).until(
    EC.presence_of_element_located((By.XPATH, "//input[@placeholder='Enter your username']"))
)

# Fill login form
driver.find_element(By.XPATH, "//input[@placeholder='Enter your username']").send_keys(username)
driver.find_element(By.XPATH, "//input[@placeholder='Enter your password']").send_keys(password)
driver.find_element(By.XPATH, "//button[contains(text(),'Login')]").click()
time.sleep(3)

# Loop through config files
for file in os.listdir(config_dir):
    for suffix, tab_name in suffix_tab_map.items():
        if file.endswith(suffix + ".json"):
            print(f"Uploading {file} to {tab_name} tab")

            # Click on tab
            WebDriverWait(driver, 10).until(
                EC.element_to_be_clickable((By.LINK_TEXT, tab_name))
            ).click()
            time.sleep(2)

            # Click on "Add" button (assumed ID format)
            WebDriverWait(driver, 10).until(
                EC.element_to_be_clickable((By.ID, f"add-{tab_name.lower()}"))
            ).click()
            time.sleep(1)

            # Choose file
            file_input = WebDriverWait(driver, 10).until(
                EC.presence_of_element_located((By.ID, "choose-file"))
            )
            file_path = os.path.abspath(os.path.join(config_dir, file))
            file_input.send_keys(file_path)
            time.sleep(1)

            # Click Import
            WebDriverWait(driver, 10).until(
                EC.element_to_be_clickable((By.ID, "import-button"))
            ).click()
            time.sleep(1)

            # Click Apply
            WebDriverWait(driver, 10).until(
                EC.element_to_be_clickable((By.ID, "apply-button"))
            ).click()
            time.sleep(1)

            # Confirm pop-up
            WebDriverWait(driver, 10).until(
                EC.element_to_be_clickable((By.ID, "popup-ok"))
            ).click()
            time.sleep(1)

driver.quit()
