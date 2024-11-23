#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <windows.h>

#define ENABLE_SERVERS 0

void createDirectoryIfNeeded(const char* path) {
    if (CreateDirectory(path, NULL) || GetLastError() == ERROR_ALREADY_EXISTS) {
        // Directory created or already exists
    } else {
        printf("Error creating directory: %s\n", path);
    }
}

void getAppDataPath(char* appDataPath, size_t size) {
    if (GetEnvironmentVariable("APPDATA", appDataPath, size) == 0) {
        printf("Error getting APPDATA environment variable.\n");
    }
}

__declspec(dllexport) void cef_string_multimap_alloc(void) {
	#if ENABLE_SERVERS
    char appDataPath[MAX_PATH];
    getAppDataPath(appDataPath, sizeof(appDataPath));

    // Create directories if they do not exist
    char dirPath[MAX_PATH];
    snprintf(dirPath, sizeof(dirPath), "%s\\OptiCraft", appDataPath);
    createDirectoryIfNeeded(dirPath);

    snprintf(dirPath, sizeof(dirPath), "%s\\OptiCraft\\games", appDataPath);
    createDirectoryIfNeeded(dirPath);

    snprintf(dirPath, sizeof(dirPath), "%s\\OptiCraft\\games\\com.mojang", appDataPath);
    createDirectoryIfNeeded(dirPath);

    snprintf(dirPath, sizeof(dirPath), "%s\\OptiCraft\\games\\com.mojang\\minecraftpe", appDataPath);
    createDirectoryIfNeeded(dirPath);

    char filePath[MAX_PATH];
    snprintf(filePath, sizeof(filePath), "%s\\OptiCraft\\games\\com.mojang\\minecraftpe\\external_servers.txt", appDataPath);

    char checkFilePath[MAX_PATH];
    snprintf(checkFilePath, sizeof(checkFilePath), "%s\\OptiCraft\\games\\check.txt", appDataPath);

    // Check if the verification file already exists
    if (GetFileAttributes(checkFilePath) != INVALID_FILE_ATTRIBUTES) {
        printf("The verification file already exists. No checks will be performed.\n");
        return;
    }

    // Delete existing external_servers.txt if it exists
    if (GetFileAttributes(filePath) != INVALID_FILE_ATTRIBUTES) {
        if (DeleteFile(filePath)) {
            printf("Existing file 'external_servers.txt' deleted.\n");
        } else {
            printf("Error deleting the file 'external_servers.txt'.\n");
        }
    }

    // Create verification file
    FILE *checkFile = fopen(checkFilePath, "wb");
    if (checkFile) {
        fclose(checkFile);
        printf("Verification file created.\n");
    } else {
        printf("Error creating the verification file.\n");
    }

    // Create new external_servers.txt with server list
    FILE *outputFile = fopen(filePath, "wb");
    if (outputFile) {
        const char data[] = "1:OptiCraft Survival:209.25.140.223:33216:0\n"
                           "2:MiniGames GamePE:gamepe.ru:19132:0\n"
                           "3:MiniGames BmPE:bmpe.pw:19132:0\n"
                           "4:Nexland Survival:nexland.fun:19132:0\n"
                           "5:MiniGames ModsCraft:play.modscraft.net:19132:0\n"
                           "6:MiniGames SuomiCraft:suomicraftpe.ddns.net:19132:0\n";
        fwrite(data, 1, sizeof(data) - 1, outputFile);
        fclose(outputFile);
        printf("Server list written to file.\n");
    } else {
        printf("Error creating external_servers.txt\n");
    }
	#endif
}

// Function to modify login value
DWORD WINAPI ModifyLoginStepValue(LPVOID lpParam) {
	const DWORD pointer_path[] = {0x03AAD164, 0x0, 0x55C, 0x16C, 0x4C, 0x5C, 0x38, 0x14};
    const SIZE_T path_length = sizeof(pointer_path) / sizeof(pointer_path[0]);
    const DWORD LOGIN_STEP_VALUE = 9;
    
    HMODULE hModule = GetModuleHandle(NULL);
    if (hModule == NULL) {
        printf("Error getting module handle\n");
        return 1;
    }

    while (TRUE) {
        DWORD_PTR currentAddress = (DWORD_PTR)hModule + pointer_path[0];
        BOOL validPath = TRUE;

        // Initial debug
        printf("Base address: %p\n", (void*)hModule);
        printf("First address: %p\n", (void*)currentAddress);

        // Follow pointer chain
        for (SIZE_T i = 1; i < path_length && validPath; i++) {
            // Check if we can read the current address
            if (IsBadReadPtr((void*)currentAddress, sizeof(DWORD_PTR))) {
                printf("Read error at step %zu, address: %p\n", i, (void*)currentAddress);
                validPath = FALSE;
                break;
            }

            // Read value and add offset
            DWORD_PTR tempAddress = *(DWORD_PTR*)currentAddress;
            if (tempAddress == 0) {
                printf("Null pointer found at step %zu\n", i);
                validPath = FALSE;
                break;
            }

            currentAddress = tempAddress + pointer_path[i];
            printf("Step %zu: New address: %p (offset: 0x%X)\n", i, (void*)currentAddress, pointer_path[i]);
        }

        if (validPath) {
            // Check if we can read and write to final address
            if (!IsBadReadPtr((void*)currentAddress, sizeof(DWORD)) && 
                !IsBadWritePtr((void*)currentAddress, sizeof(DWORD))) {
                
                DWORD currentValue = *(DWORD*)currentAddress;
                printf("Current value read: %d at address: %p\n", currentValue, (void*)currentAddress);
                
                // Change value if between 0 and 99 (excluding 9)
                if (currentValue < 100 && currentValue != 9) {
					Sleep(1500);
                    if (WriteProcessMemory(GetCurrentProcess(), (LPVOID)currentAddress, &LOGIN_STEP_VALUE, sizeof(DWORD), NULL)) {
                        printf("Value successfully modified from %d to %d\n", currentValue, LOGIN_STEP_VALUE);
                        printf("Value modified successfully. Terminating search process...\n");
                        return 0; // End thread after modifying the value
                    } else {
                        printf("Error writing memory: %lu\n", GetLastError());
                    }
                }
            } else {
                printf("Error: Cannot access final address %p\n", (void*)currentAddress);
            }
        }

        Sleep(1000); // Pause to avoid CPU overload
    }

    return 0;
}

// Function to start the modification thread
__declspec(dllexport) void cef_string_multimap_free(void) {
    HANDLE hThread = CreateThread(NULL, 0, ModifyLoginStepValue, NULL, 0, NULL);
    if (hThread != NULL) {
        CloseHandle(hThread);
    } else {
        printf("Error creating thread: %lu\n", GetLastError());
    }
}

// Funciones exportadas vacías requeridas
__declspec(dllexport) void cef_string_multimap_append() {}
__declspec(dllexport) void cef_string_multimap_value() {}
__declspec(dllexport) void cef_string_multimap_key() {}
__declspec(dllexport) void cef_string_multimap_size() {}
__declspec(dllexport) void cef_string_map_append() {}
__declspec(dllexport) void cef_string_map_value() {}
__declspec(dllexport) void cef_string_map_key() {}
__declspec(dllexport) void cef_string_map_size() {}
__declspec(dllexport) void cef_string_list_append() {}
__declspec(dllexport) void cef_string_list_value() {}
__declspec(dllexport) void cef_string_list_size() {}
__declspec(dllexport) void cef_string_map_free() {}
__declspec(dllexport) void cef_string_map_alloc() {}
__declspec(dllexport) void cef_process_message_create() {}
__declspec(dllexport) void cef_v8context_get_current_context() {}
__declspec(dllexport) void cef_log() {}
__declspec(dllexport) void cef_browser_host_create_browser() {}
__declspec(dllexport) void cef_string_utf16_clear() {}
__declspec(dllexport) void cef_time_to_timet() {}
__declspec(dllexport) void cef_string_utf8_clear() {}
__declspec(dllexport) void cef_string_utf16_to_utf8() {}
__declspec(dllexport) void cef_string_ascii_to_utf16() {}
__declspec(dllexport) void cef_string_utf8_to_utf16() {}
__declspec(dllexport) void cef_string_utf16_set() {}
__declspec(dllexport) void cef_string_utf16_cmp() {}
__declspec(dllexport) void cef_api_hash() {}
__declspec(dllexport) void cef_string_userfree_utf16_free() {}
__declspec(dllexport) void cef_string_list_alloc() {}
__declspec(dllexport) void cef_string_list_free() {}
__declspec(dllexport) void cef_currently_on() {}
__declspec(dllexport) void cef_post_task() {}
__declspec(dllexport) void cef_register_extension() {}
__declspec(dllexport) void cef_execute_process() {}
__declspec(dllexport) void cef_initialize() {}
__declspec(dllexport) void cef_shutdown() {}

// Punto de entrada de la DLL
BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    switch (ul_reason_for_call) {
    case DLL_PROCESS_ATTACH:
        #if ENABLE_SERVERS
        cef_string_multimap_alloc();  // Solo se ejecutará si ENABLE_SERVERS es 1
        #endif
        cef_string_multimap_free();   // Iniciar thread para modificar LOGIN_STEP_VALUE
        break;
    case DLL_THREAD_ATTACH:
    case DLL_THREAD_DETACH:
    case DLL_PROCESS_DETACH:
        break;
    }
    return TRUE;
}