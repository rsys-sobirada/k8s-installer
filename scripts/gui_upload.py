from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time, os

# EMS credentials and config path
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"
config_dir = "config_files"

# Mapping suffix to tab name
suffix_tab_map = {
    "_amf": "AMF",
    "_smf": "SMF",
    "_upf": "UPF"
}

# Setup Firefox options for Jenkins
options = Options()
options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")

# Start Firefox WebDriver
driver = webdriver.Firefox(options=options)

# Utility Functions
def click_nf_tab(driver, nf_name):
    driver.save_screenshot(f"{nf_name.lower()}_tab_debug.png")
    xpath = f"//div[contains(text(), '{nf_name}') or contains(text(), '{nf_name.lower()}')]"
    WebDriverWait(driver, 15).until(
        EC.element_to_be_clickable((By.XPATH, xpath))
    ).click()

def click_add_button(driver, nf_name):
    xpath = f"//div[contains(text(), 'Add') and contains(text(), '{nf_name.lower()}')]"
    WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, xpath))
    ).click()

def upload_config_file(driver, file_path):
    file_input = WebDriverWait(driver, 10).until(
        EC.presence_of_element_located((By.XPATH, "//input[@type='file']"))
    )
    file_input.send_keys(file_path)

def click_import(driver):
    WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, "//button[contains(text(), 'Import')]"))
    ).click()

def click_apply(driver):
    WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, "//button[contains(text(), 'Apply')]"))
    ).click()

def confirm_popup(driver):
    WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, "//button[contains(text(), 'OK')]"))
    ).click()

# Start automation
driver.get(url)
time.sleep(2)
driver.save_screenshot("login_page_debug.png")

# Login
WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.XPATH, "//input[@placeholder='Enter your username']"))
)
driver.find_element(By.XPATH, "//input[@placeholder='Enter your username']").send_keys(username)
driver.find_element(By.XPATH, "//input[@placeholder='Enter your password']").send_keys(password)
driver.find_element(By.XPATH, "//button[contains(text(),'Login')]").click()
time.sleep(3)

# Loop through config files with logging
print("Scanning config_files directory...")
for file in os.listdir(config_dir):
    print(f"Checking file: {file}")
    for suffix, nf_name in suffix_tab_map.items():
        expected_suffix = suffix + ".json"
        if file.endswith(expected_suffix):
            print(f"Matched file '{file}' with suffix '{suffix}' → NF tab: {nf_name}")
            file_path = os.path.abspath(os.path.join(config_dir, file))

            click_nf_tab(driver, nf_name)
            click_add_button(driver, nf_name)
            upload_config_file(driver, file_path)
            click_import(driver)
            click_apply(driver)
            confirm_popup(driver)

driver.quit()
