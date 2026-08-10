/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this
 * software and associated documentation files (the "Software"), to deal in the Software
 * without restriction, including without limitation the rights to use, copy, modify,
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so.
 */

package com.amazon.sample.ui.web;

import java.net.URI;
import java.time.Duration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseCookie;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import reactor.core.publisher.Mono;

@Controller
public class AuthenticationController {

  private static final int MAX_ALB_COOKIE_SHARDS = 4;

  private final String logoutUrl;
  private final String sessionCookieName;

  public AuthenticationController(
    @Value("${retail.ui.auth.logout-url:/}") String logoutUrl,
    @Value(
      "${retail.ui.auth.session-cookie-name:retail-store-auth}"
    ) String sessionCookieName
  ) {
    this.logoutUrl = logoutUrl;
    this.sessionCookieName = sessionCookieName;
  }

  @GetMapping("/auth/logout")
  public Mono<Void> logout(ServerHttpResponse response) {
    expireCookie(response, sessionCookieName);

    for (int shard = 0; shard < MAX_ALB_COOKIE_SHARDS; shard++) {
      expireCookie(response, sessionCookieName + "-" + shard);
    }

    response.setStatusCode(HttpStatus.FOUND);
    response.getHeaders().setLocation(URI.create(logoutUrl));

    return response.setComplete();
  }

  private void expireCookie(ServerHttpResponse response, String cookieName) {
    response.addCookie(
      ResponseCookie.from(cookieName, "")
        .httpOnly(true)
        .secure(true)
        .sameSite("None")
        .path("/")
        .maxAge(Duration.ZERO)
        .build()
    );
  }
}
