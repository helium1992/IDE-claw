package handler

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"time"

	"push-server/config"
	"push-server/store"
)

const windsurfFirebaseAPIKey = "AIzaSyDsOl-1XpT5err0Tcnx8FFod1H8gVGIycY"
const windsurfFirebaseSignInURL = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=" + windsurfFirebaseAPIKey
const windsurfRegisterUserURL = "https://api.codeium.com/register_user/"
const windsurfUserStatusURL = "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
const windsurfBrowserReferer = "https://windsurf.com/"
const windsurfBrowserOrigin = "https://windsurf.com"
const windsurfBrowserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"

func postJSONPayload(url string, payload interface{}) (int, map[string]interface{}, error) {
	return postJSONPayloadWithHeaders(url, payload, nil)
}

func postJSONPayloadWithHeaders(url string, payload interface{}, headers map[string]string) (int, map[string]interface{}, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return 0, nil, err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	for key, value := range headers {
		if key == "" || value == "" {
			continue
		}
		req.Header.Set(key, value)
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	data := map[string]interface{}{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &data); err != nil {
			data = map[string]interface{}{"raw": string(raw)}
		}
	}
	return resp.StatusCode, data, nil
}

func postBinaryPayload(url string, payload []byte, headers map[string]string) (int, []byte, http.Header, error) {
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return 0, nil, nil, err
	}
	for key, value := range headers {
		if key == "" || value == "" {
			continue
		}
		req.Header.Set(key, value)
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, resp.Header, err
	}
	return resp.StatusCode, raw, resp.Header, nil
}

func encodeVarint(n int) []byte {
	buf := make([]byte, 0, 8)
	for n > 127 {
		buf = append(buf, byte((n&0x7F)|0x80))
		n >>= 7
	}
	buf = append(buf, byte(n))
	return buf
}

func encodeProtoLengthDelimited(fieldNum int, data []byte) []byte {
	if len(data) == 0 {
		return []byte{}
	}
	tag := encodeVarint((fieldNum << 3) | 2)
	length := encodeVarint(len(data))
	result := make([]byte, len(tag)+len(length)+len(data))
	copy(result, tag)
	copy(result[len(tag):], length)
	copy(result[len(tag)+len(length):], data)
	return result
}

func encodeProtoStringField(value string) []byte {
	if value == "" {
		return []byte{}
	}
	return encodeProtoLengthDelimited(1, []byte(value))
}

func encodeProtoStringFieldN(fieldNum int, value string) []byte {
	if value == "" {
		return []byte{}
	}
	return encodeProtoLengthDelimited(fieldNum, []byte(value))
}

func buildGetUserStatusRequest(apiKey string) []byte {
	// Metadata: field 1=ide_name, field 2=extension_version, field 3=api_key, field 4=locale
	metadataInner := make([]byte, 0, 256)
	metadataInner = append(metadataInner, encodeProtoStringFieldN(1, "windsurf")...)
	metadataInner = append(metadataInner, encodeProtoStringFieldN(2, "2.6.2")...)
	metadataInner = append(metadataInner, encodeProtoStringFieldN(3, apiKey)...)
	metadataInner = append(metadataInner, encodeProtoStringFieldN(4, "en")...)
	// GetUserStatusRequest: field 1 = metadata (message)
	return encodeProtoLengthDelimited(1, metadataInner)
}

func decodeProtoStringField(data []byte) string {
	if len(data) <= 2 || data[0] != 0x0A {
		return ""
	}
	length := 0
	shift := 0
	position := 1
	for position < len(data) {
		current := data[position]
		position++
		length |= int(current&0x7F) << shift
		if (current & 0x80) == 0 {
			break
		}
		shift += 7
		if shift > 63 {
			return ""
		}
	}
	if length <= 0 || position+length > len(data) {
		return ""
	}
	return string(data[position : position+length])
}

func payloadString(payload map[string]interface{}, key string) string {
	if payload == nil {
		return ""
	}
	if value, ok := payload[key]; ok {
		if text, ok := value.(string); ok {
			return text
		}
	}
	return ""
}

func windsurfFirebaseHeaders() map[string]string {
	return map[string]string{
		"Referer":    windsurfBrowserReferer,
		"Origin":     windsurfBrowserOrigin,
		"User-Agent": windsurfBrowserUA,
	}
}

func nestedPayloadString(payload map[string]interface{}, parentKey, childKey string) string {
	if payload == nil {
		return ""
	}
	child, ok := payload[parentKey].(map[string]interface{})
	if !ok {
		return ""
	}
	if value, ok := child[childKey]; ok {
		if text, ok := value.(string); ok {
			return text
		}
	}
	return ""
}

func payloadErrorMessage(payload map[string]interface{}) string {
	if message := payloadString(payload, "message"); message != "" {
		return message
	}
	if message := payloadString(payload, "detail"); message != "" {
		return message
	}
	if message := payloadString(payload, "error_description"); message != "" {
		return message
	}
	if child, ok := payload["error"].(map[string]interface{}); ok {
		if value, ok := child["message"].(string); ok && value != "" {
			return value
		}
		if value, ok := child["status"].(string); ok && value != "" {
			return value
		}
	}
	if value, ok := payload["error"].(string); ok && value != "" {
		return value
	}
	if raw := payloadString(payload, "raw"); raw != "" {
		return raw
	}
	return ""
}

func WindsurfLogin(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email    string `json:"email"`
			Password string `json:"password"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.Email == "" || req.Password == "" {
			errorJSON(w, 400, "email 和 password 不能为空")
			return
		}

		firebaseStatus, firebasePayload, err := postJSONPayloadWithHeaders(windsurfFirebaseSignInURL, map[string]interface{}{
			"email":             req.Email,
			"password":          req.Password,
			"returnSecureToken": true,
		}, windsurfFirebaseHeaders())
		if err != nil {
			errorJSON(w, 502, "官方 Firebase 请求失败: "+err.Error())
			return
		}
		if firebaseStatus != 200 {
			message := payloadErrorMessage(firebasePayload)
			if message == "" {
				message = "官方 Firebase 登录失败"
			}
			errorJSON(w, 502, message)
			return
		}

		idToken := payloadString(firebasePayload, "idToken")
		refreshToken := payloadString(firebasePayload, "refreshToken")
		expiresIn := payloadString(firebasePayload, "expiresIn")
		if idToken == "" {
			errorJSON(w, 502, "官方 Firebase 响应中没有 idToken")
			return
		}

		registerStatus, registerPayload, err := postJSONPayload(windsurfRegisterUserURL, map[string]interface{}{
			"firebase_id_token": idToken,
		})
		if err != nil {
			errorJSON(w, 502, "register_user 请求失败: "+err.Error())
			return
		}
		if registerStatus != 200 {
			message := payloadErrorMessage(registerPayload)
			if message == "" {
				message = "register_user 失败"
			}
			errorJSON(w, 502, message)
			return
		}

		authToken := payloadString(registerPayload, "api_key")
		if authToken == "" {
			authToken = payloadString(registerPayload, "token")
		}
		if authToken == "" {
			authToken = payloadString(registerPayload, "authToken")
		}
		if authToken == "" {
			authToken = nestedPayloadString(registerPayload, "data", "api_key")
		}
		if authToken == "" {
			authToken = nestedPayloadString(registerPayload, "data", "token")
		}
		if authToken == "" {
			authToken = nestedPayloadString(registerPayload, "data", "authToken")
		}
		if authToken == "" {
			errorJSON(w, 502, "register_user 响应中没有 auth token")
			return
		}

		expireTime := int64(0)
		if expiresIn != "" {
			if seconds, err := strconv.Atoi(expiresIn); err == nil {
				if seconds > 300 {
					expireTime = time.Now().Add(time.Duration(seconds-300) * time.Second).UnixMilli()
				} else {
					expireTime = time.Now().Add(50 * time.Minute).UnixMilli()
				}
			}
		}

		writeJSON(w, 200, map[string]interface{}{
			"status":        "success",
			"email":         req.Email,
			"id_token":      idToken,
			"refresh_token": refreshToken,
			"expires_in":    expiresIn,
			"expire_time":   expireTime,
			"auth_token":    authToken,
			"source":        "faceflow_server",
		})
	}
}

func WindsurfFirebaseLogin(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req map[string]interface{}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		email := payloadString(req, "email")
		password := payloadString(req, "password")
		if email == "" || password == "" {
			errorJSON(w, 400, "email 和 password 不能为空")
			return
		}
		firebaseStatus, firebasePayload, err := postJSONPayloadWithHeaders(windsurfFirebaseSignInURL, map[string]interface{}{
			"email":             email,
			"password":          password,
			"returnSecureToken": true,
		}, windsurfFirebaseHeaders())
		if err != nil {
			errorJSON(w, 502, "官方 Firebase 请求失败: "+err.Error())
			return
		}
		if firebaseStatus != 200 {
			message := payloadErrorMessage(firebasePayload)
			if message == "" {
				message = "官方 Firebase 登录失败"
			}
			errorJSON(w, 502, message)
			return
		}
		writeJSON(w, 200, firebasePayload)
	}
}

const windsurfGetOTTURL = "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetOneTimeAuthToken"

func WindsurfAuthToken(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		requestBytes, err := io.ReadAll(r.Body)
		if err != nil {
			errorJSON(w, 400, "读取请求体失败: "+err.Error())
			return
		}
		if len(requestBytes) == 0 {
			errorJSON(w, 400, "请求体为空")
			return
		}
		// 直接将 protobuf 请求原样转发到 Codeium 官方 GetOneTimeAuthToken 端点
		proxyHeaders := map[string]string{
			"Content-Type":             "application/proto",
			"connect-protocol-version": "1",
			"Origin":                   windsurfBrowserOrigin,
			"User-Agent":               windsurfBrowserUA,
		}
		statusCode, responseBytes, respHeaders, err := postBinaryPayload(windsurfGetOTTURL, requestBytes, proxyHeaders)
		if err != nil {
			errorJSON(w, 502, "官方 GetOneTimeAuthToken 请求失败: "+err.Error())
			return
		}
		// 透传响应 Content-Type
		ct := "application/proto"
		if h := respHeaders.Get("Content-Type"); h != "" {
			ct = h
		}
		w.Header().Set("Content-Type", ct)
		w.WriteHeader(statusCode)
		_, _ = w.Write(responseBytes)
	}
}

const windsurfGetPlanStatusURL = "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetPlanStatus"

func WindsurfPlanStatus(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		requestBytes, err := io.ReadAll(r.Body)
		if err != nil {
			errorJSON(w, 400, "读取请求体失败: "+err.Error())
			return
		}
		if len(requestBytes) == 0 {
			errorJSON(w, 400, "请求体为空")
			return
		}
		// 直接将 protobuf 请求原样转发到 Codeium 官方 GetPlanStatus 端点
		// 该端点接受 protobuf(idToken) 并返回 protobuf(PlanStatus)
		proxyHeaders := map[string]string{
			"Content-Type":             "application/proto",
			"connect-protocol-version": "1",
			"Origin":                   windsurfBrowserOrigin,
			"User-Agent":               windsurfBrowserUA,
		}
		statusCode, responseBytes, respHeaders, err := postBinaryPayload(windsurfGetPlanStatusURL, requestBytes, proxyHeaders)
		if err != nil {
			errorJSON(w, 502, "官方 GetPlanStatus 请求失败: "+err.Error())
			return
		}
		// 透传响应
		ct := "application/proto"
		if h := respHeaders.Get("Content-Type"); h != "" {
			ct = h
		}
		w.Header().Set("Content-Type", ct)
		w.WriteHeader(statusCode)
		_, _ = w.Write(responseBytes)
	}
}

// ImportWindsurfAccounts 批量导入/更新 Windsurf 账号
func ImportWindsurfAccounts(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Accounts []store.WindsurfAccountInput `json:"accounts"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if len(req.Accounts) == 0 {
			errorJSON(w, 400, "accounts 不能为空")
			return
		}
		count, err := db.UpsertWindsurfAccounts(req.Accounts)
		if err != nil {
			errorJSON(w, 500, "导入失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{
			"imported": count,
			"total":    len(req.Accounts),
		})
	}
}

// ListWindsurfAccounts 列出所有 Windsurf 账号（不返回密码）
func ListWindsurfAccounts(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		accounts, err := db.ListWindsurfAccounts()
		if err != nil {
			errorJSON(w, 500, "查询失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{
			"accounts": accounts,
		})
	}
}

// ClaimWindsurfAccount 领取一个可用账号
func ClaimWindsurfAccount(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			MachineID   string `json:"machine_id"`
			PreferDaily bool   `json:"prefer_daily"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.MachineID == "" {
			req.MachineID = "unknown"
		}
		account, err := db.ClaimWindsurfAccount(req.MachineID)
		if err != nil {
			errorJSON(w, 500, "领取失败: "+err.Error())
			return
		}
		if account == nil {
			errorJSON(w, 404, "没有可用账号")
			return
		}
		writeJSON(w, 200, account)
	}
}

// ReleaseWindsurfAccount 释放一个账号
func ReleaseWindsurfAccount(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			MachineID    string `json:"machine_id"`
			Email        string `json:"email"`
			CreditsDairy int    `json:"credits_daily"`
			CreditsWeek  int    `json:"credits_weekly"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.Email == "" {
			errorJSON(w, 400, "email 不能为空")
			return
		}
		err := db.ReleaseWindsurfAccount(req.Email, req.MachineID, req.CreditsDairy, req.CreditsWeek)
		if err != nil {
			errorJSON(w, 500, "释放失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{"released": true})
	}
}

// WindsurfAccountStatus 获取账号池状态
func WindsurfAccountStatus(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		status, err := db.GetWindsurfAccountStatus()
		if err != nil {
			errorJSON(w, 500, "查询失败: "+err.Error())
			return
		}
		writeJSON(w, 200, status)
	}
}
