<?php

namespace App\Controllers;

use App\Models\Node;
use App\Models\User;
use App\Services\Config;
use App\Models\TrafficLog;
use App\Models\NodeOnlineLog;
use App\Utils\Tools;

/**
 * Hysteria2 服务端对接接口
 *
 * 通过 Hysteria2 的 HTTP 认证（auth.type: http）校验用户，
 * 使用 muKey 作为接口鉴权，避免依赖节点 IP 校验。
 */
class Hysteria2Controller extends BaseController
{
    /**
     * 校验请求携带的 muKey
     *
     * @param \Slim\Http\Request $request
     *
     * @return bool
     */
    private function checkKey($request)
    {
        $key = $request->getQueryParam('key');
        if ($key === null) {
            return false;
        }
        return in_array($key, Config::getMuKey());
    }

    /**
     * Hysteria2 HTTP 认证
     *
     * 请求体：{"addr":"1.2.3.4:1234","auth":"用户uuid或连接密码","tx":0}
     * 响应体：{"ok":true,"id":"用户ID"}
     *
     * @param \Slim\Http\Request  $request
     * @param \Slim\Http\Response $response
     * @param array               $args
     *
     * @return \Slim\Http\Response
     */
    public function auth($request, $response, $args)
    {
        if (!$this->checkKey($request)) {
            return $response->withJson(['ok' => false, 'id' => '']);
        }

        $body = json_decode($request->getBody()->getContents(), true);
        $auth = (is_array($body) && isset($body['auth'])) ? trim((string) $body['auth']) : '';

        $ok = false;
        $id = '';
        if ($auth !== '') {
            $user = User::where('uuid', '=', $auth)->first();
            if ($user == null) {
                $user = User::where('passwd', '=', $auth)->first();
            }

            if ($user != null && $user->enable == 1 && strtotime($user->expire_in) > time()) {
                $node_ok = true;
                $node_id = $request->getQueryParam('node_id');
                if ($node_id !== null) {
                    $node = Node::find($node_id);
                    if ($node != null) {
                        if ($user->class < $node->node_class) {
                            $node_ok = false;
                        }
                        if ($node->node_group != 0 && $user->node_group != $node->node_group) {
                            $node_ok = false;
                        }
                    }
                }
                if ($node_ok) {
                    $ok = true;
                    $id = (string) $user->id;
                }
            }
        }

        return $response->withJson(['ok' => $ok, 'id' => $id]);
    }

    /**
     * Hysteria2 流量上报
     *
     * 请求体：{"node_id":1,"data":[{"user_id":1,"u":123,"d":456}]}
     * 其中 u 为客户端上行、d 为客户端下行，单位字节。
     *
     * @param \Slim\Http\Request  $request
     * @param \Slim\Http\Response $response
     * @param array               $args
     *
     * @return \Slim\Http\Response
     */
    public function traffic($request, $response, $args)
    {
        if (!$this->checkKey($request)) {
            return $response->withJson(['ok' => false, 'msg' => 'invalid key']);
        }

        $body = json_decode($request->getBody()->getContents(), true);
        $node_id = (is_array($body) && isset($body['node_id'])) ? (int) $body['node_id'] : 0;
        $data = (is_array($body) && isset($body['data']) && is_array($body['data'])) ? $body['data'] : [];

        $node = Node::find($node_id);
        if ($node == null) {
            return $response->withJson(['ok' => false, 'msg' => 'node not found']);
        }

        $total = 0;
        foreach ($data as $log) {
            if (!isset($log['user_id'], $log['u'], $log['d'])) {
                continue;
            }
            $u = (float) $log['u'];
            $d = (float) $log['d'];
            $user = User::find((int) $log['user_id']);
            if ($user == null) {
                continue;
            }

            $user->t = time();
            $user->u += $u * $node->traffic_rate;
            $user->d += $d * $node->traffic_rate;
            $user->save();

            $total += $u + $d;

            $traffic = new TrafficLog();
            $traffic->user_id = (int) $log['user_id'];
            $traffic->u = $u;
            $traffic->d = $d;
            $traffic->node_id = $node_id;
            $traffic->rate = $node->traffic_rate;
            $traffic->traffic = Tools::flowAutoShow(($u + $d) * $node->traffic_rate);
            $traffic->log_time = time();
            $traffic->save();
        }

        $node->node_bandwidth += $total;
        $node->node_heartbeat = time();
        $node->save();

        $online_log = new NodeOnlineLog();
        $online_log->node_id = $node_id;
        $online_log->online_user = count($data);
        $online_log->log_time = time();
        $online_log->save();

        return $response->withJson(['ok' => true, 'msg' => 'ok']);
    }
}
